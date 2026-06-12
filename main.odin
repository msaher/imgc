package main

import "base:runtime"
import "core:c"
import "core:os"
import "core:fmt"
import "core:strings"

import "imlib"

import sdl "vendor:sdl3"
import sdl_ttf "vendor:sdl3/ttf"

// general purpose builder. Resets every frame
g_builder: strings.Builder


// get a *temporary* cstring
as_cstring :: proc(s: string) -> cstring {
    strings.builder_reset(&g_builder)
    strings.write_string(&g_builder, s)
    return strings.to_cstring(&g_builder)
}

// TODO: store file path also as given by argv instead of full
// path
Image :: struct {
    thumbnail: ^sdl.Texture,
    file: os.File_Info,
    im: imlib.Image
}

image_load :: proc(img: ^Image) -> bool {
    // maybe use builder
    p := as_cstring(img.file.fullpath)
    img.im = imlib.load_image(p)
    if img.im == nil {
        return false
    }
    return true
}

image_unload :: proc(img: ^Image) {
    imlib.context_set_image(img.im)
    imlib.free_image()
    img.im = nil
}

PAN_SPEED :: 100
ZOOM_LEVELS := []f32{0.12, 0.25, 0.50, 0.75, 1.00, 1.50, 2.00, 4.00, 8.00}
DEFAULT_ZOOM_LEVEL :: 4

Focus_State :: struct {
    panned_x: f32,
    panned_y: f32,
    zoom_idx: int,
    img: ^Image,
    texture: ^sdl.Texture,
}

MAX_THUMB :: 160
MIN_THUMB :: 32

Grid :: struct {
    images: [dynamic]Image,
    n_loaded: int,
    selected: int,
    thumb: f32,

    // for drawing
    n_cols: int,
    first_visible_row: int,
}

grid_are_all_loaded :: proc(g: ^Grid) -> bool {
    return g.n_loaded == len(g.images)
}

grid_selected_image :: proc(g: ^Grid) -> ^Image {
    return &g.images[g.selected]
}

grid_select_next :: proc(g: ^Grid, i: int) {
    g.selected = clamp(g.selected+i, 0, len(g.images)-1)
}

grid_select_prev :: proc(g: ^Grid, i: int) {
    grid_select_next(g, -i)
}

grid_load_next_img :: proc(g: ^Grid, renderer: ^sdl.Renderer) -> bool {
    idx := g.n_loaded
    img := &g.images[idx]
    path := img.file.fullpath

    ok := image_load(img)
    if !ok {
        fmt.fprintf(os.stderr, "%s: %d\n", path, imlib.get_error())
        return false
    }

    // scale image down
    ok = image_scale_down(img, MAX_THUMB)
    if !ok {
        fmt.fprintf(os.stderr, "%s: failed to scale image: %d\n", path, imlib.get_error())
        return false
    }

    // do we really need to do this?
    // free scaled image
    defer image_unload(img)

    thumbnail, ok1 := create_texture_from_image(renderer, img)
    if !ok1 {
        return false
    }
    img.thumbnail = thumbnail

    g.n_loaded += 1
    return true
}

image_scale_down :: proc(img: ^Image, thumb: f32) -> bool {
    imlib.context_set_image(img.im)
    wi := imlib.image_get_width()
    hi := imlib.image_get_height()
    w := f32(wi)
    h := f32(hi)

    scale := min(thumb / w, thumb / h)
	scale = min(scale, 1.0);

    if scale < 1 {
        imlib.context_set_anti_alias(true)
        im_scaled := imlib.create_cropped_scaled_image(0, 0, wi, hi, i32(scale*w), i32(scale*h))
        imlib.free_image_and_decache()
        img.im = im_scaled
        return img.im != nil
    }
    return true
}

create_texture_from_image :: proc(renderer: ^sdl.Renderer, img: ^Image) -> (^sdl.Texture, bool) {
    imlib.context_set_image(img.im)
    w := imlib.image_get_width()
    h := imlib.image_get_height()
    pixels := imlib.image_get_data_for_reading_only()
    // TODO: use path as given by argc
    if pixels == nil {
        fmt.fprintf(os.stderr, "%s: can't load image: %d\n", img.file.fullpath, imlib.get_error())
        return nil, false
    }

    t := sdl.CreateTexture(renderer, .ARGB8888, .STATIC, w, h)
    updated := false
    if t != nil {
        updated = sdl.UpdateTexture(t, nil, rawptr(pixels), w * size_of(c.uint32_t))
    }

    if t == nil || !updated {
        fmt.fprintf(os.stderr, "%s: can't load texture: %s\n", img.file.fullpath, sdl.GetError())
        return nil, false
    }

    return t, true
}

sorted_inject :: proc(s: ^[dynamic]int, value: int) -> runtime.Allocator_Error {
    if len(s) == 0 {
        _, err := append(s, value)
        return err
    }

    for i in 0..<len(s) {
        if s[i] >= value {
            _, err := inject_at(s, i, value)
            return err
        }
    }
    _, err := append(s, value)
    return err
}

draw_focus :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, fc: ^Focus_State, img: ^Image) {
    // set image... maybe make proc
    if fc.img != img {
        fc.img = img
        if fc.texture != nil {
            sdl.DestroyTexture(fc.texture)
        }
        image_load(fc.img)
        defer image_unload(fc.img)
        t, ok := create_texture_from_image(renderer, img)
        if !ok {
            return
        }
        fc.texture = t
    }

    ww, wh: c.int
    sdl.GetWindowSize(window, &ww, &wh)

    tw, th: f32
    sdl.GetTextureSize(fc.texture, &tw, &th)
    scale := min(f32(ww)/tw, f32(wh)/th)
    if scale > 1 {
        scale = 1
    }
    zoom := ZOOM_LEVELS[fc.zoom_idx]
    scale *= zoom
    dst := sdl.FRect {
        h = scale*th,
        w = scale*tw,
    }

    dst.x = (f32(ww)-dst.w)/2
    dst.y = (f32(wh)-dst.h)/2

    if dst.h > f32(wh) {
        // clamp: image edge can't go past window edge
        // top edge: we draw at point 0
        // bottom edge: we draw at point wh-dst.y We intentionally want negative sign
        // Why wh-dst.h? Because that's where y starts when panned all the way to bottom.

        // So dst.y+panned_y in range [f32(wh)-dst.h, 0]
        // panned_y in range [f32(wh)-dst.h-dst.y, 0-dst.y]
        fc.panned_y = clamp(
            fc.panned_y,
            f32(wh) - dst.h - dst.y,
            -dst.y,
        )
        dst.y += fc.panned_y
    } else {
        // no panning when image is fully visible
        fc.panned_y = 0
    }

    if dst.w > f32(ww) {
        fc.panned_x = clamp(
            fc.panned_x,
            f32(ww) - dst.w - dst.x,
            -dst.x,
        )
        dst.x += fc.panned_x
    } else {
        fc.panned_x = 0
    }

    sdl.RenderTexture(renderer, fc.texture, nil, &dst)
}

draw_grid :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, grid: ^Grid) {
    // suppose thumb :: 200
    // (400x200) --> (200x100), scale = 0.5
    // (800x600) --> (200x150), scale = 0.25
    // max(tw*th)*scale = thumbnail = 200
    vh, vw: f32
    {
        ww, wh: c.int
        sdl.GetWindowSize(window, &ww, &wh)
        padding :: 50
        vw = f32(ww)-padding
        vh = f32(wh)-padding
    }
    gap: f32 : 20

    stride := grid.thumb+gap
    grid.n_cols = int(f32(vw)/(stride))
    if grid.n_cols < 1 {
        grid.n_cols = 1
    }

    total_rows := (len(grid.images) + grid.n_cols - 1) / grid.n_cols
    capacity_rows := int(vh/stride) // how many rows can we show at once?
    visible_rows := min(total_rows, capacity_rows)

    // when we zoom out (decrease thumb) the number of visible_rows increases
    // hence, the greatest valid first_visible_row = total-rows-visible,
    // allowing us to see more as we zoom out. However, we may already be at
    // the top of the grid, meaning grid.first_visible_row is already lower
    // than greatest valid first row, so we use min
    grid.first_visible_row = min(grid.first_visible_row, total_rows - visible_rows)
    // if total_rows is less than visible_rows we get negative. Invalid
    grid.first_visible_row = max(grid.first_visible_row, 0)

    selected_row := grid.selected / grid.n_cols
    last_visible_row := grid.first_visible_row + visible_rows - 1
    if last_visible_row >= total_rows {
        last_visible_row = total_rows-1
    }

    if selected_row > last_visible_row {
        grid.first_visible_row += 1
    } else if selected_row < grid.first_visible_row {
        grid.first_visible_row -= 1
    }


    grid_h := f32(visible_rows) * stride - gap
    y_offset := (f32(vh) - grid_h) / 2

    // center grid x axis
    grid_w := f32(grid.n_cols)*stride - gap
    x_offset := (f32(vw) - grid_w) / 2

    dst: sdl.FRect
    for i in 0..<len(grid.images) {
        t := grid.images[i].thumbnail
        if t == nil { // no need
            continue
        }
        row := i / grid.n_cols
        if row < grid.first_visible_row || row > last_visible_row {
            continue
        }
        col := i % grid.n_cols

        tw, th: f32
        sdl.GetTextureSize(t, &tw, &th)
        scale := min(f32(grid.thumb) / tw, f32(grid.thumb) / th)
        dst.w = tw*scale
        dst.h = th*scale

        dst.x = x_offset + f32(col)*f32(stride) + (grid.thumb - dst.w)/2
        visible_row := row - grid.first_visible_row
        dst.y = y_offset + f32(visible_row)*f32(stride) + (grid.thumb - dst.h)/2

        // draw a box
        if i == grid.selected {
            sdl.SetRenderDrawColor(renderer, 80, 160, 255, 255)
            thickness :: 3
            for j in 0..<thickness {
                r := sdl.FRect{
                    x = dst.x - f32(j),
                    y = dst.y - f32(j),
                    w = dst.w + f32(j)*2,
                    h = dst.h + f32(j)*2,
                }
                sdl.RenderRect(renderer, &r)
            }
        }

        if t != nil {
            sdl.RenderTexture(renderer, t, nil, &dst)
        }
    }
}

draw_bar :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, grid: ^Grid, focus_state: ^Focus_State, focus_mode: bool, font: ^sdl_ttf.Font) {

    filename := grid_selected_image(grid).file.fullpath
    cfilename := strings.unsafe_string_to_cstring(filename)

    surface := sdl_ttf.RenderText_Blended(font, cfilename, len(filename), sdl.Color{255, 255, 255, 255})
    text_left := sdl.CreateTextureFromSurface(renderer, surface)
    sdl.DestroySurface(surface)
    defer sdl.DestroyTexture(text_left)

    b := &g_builder
    strings.builder_reset(b)
    if focus_mode {
        strings.write_int(b, int(ZOOM_LEVELS[focus_state.zoom_idx]*100))
        strings.write_string(b, "% ")
    }
    // abstract this
    strings.write_int(b, grid.selected+1)
    strings.write_byte(b, '/')
    strings.write_int(b, len(grid.images))
    counter := strings.to_string(b^)
    ccounter := strings.unsafe_string_to_cstring(counter)
    surface = sdl_ttf.RenderText_Blended(font, ccounter, len(counter), sdl.Color{255, 255, 255, 255})
    text_right := sdl.CreateTextureFromSurface(renderer, surface)
    sdl.DestroySurface(surface)
    defer sdl.DestroyTexture(text_right)

    tw, th: f32
    sdl.GetTextureSize(text_left, &tw, &th)

    // draw bar
    ww, wh: c.int
    sdl.GetWindowSize(window, &ww, &wh)

    sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
    bar_h := th
    bar_rect := sdl.FRect {
        x = 0,
        w = f32(ww),
        h = f32(bar_h),
        y = f32(wh) - f32(bar_h),
    }
    sdl.RenderFillRect(renderer, &bar_rect)

    // draw text
    dst := bar_rect
    dst.x += 10 // padding
    dst.w = tw
    dst.h = th
    sdl.RenderTexture(renderer, text_left, nil, &dst)

    sdl.GetTextureSize(text_right, &tw, &th)
    dst.y = bar_rect.y
    dst.x = f32(ww)-tw-10
    dst.h = th
    dst.w = tw
    sdl.RenderTexture(renderer, text_right, nil, &dst)
}

draw :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, bar: bool, focus_mode: bool, g: ^Grid, f: ^Focus_State, font: ^sdl_ttf.Font) {
    sdl.SetRenderDrawColor(renderer, 20, 20, 20, 255)
    sdl.RenderClear(renderer)

    if focus_mode {
        img := grid_selected_image(g)
        draw_focus(window, renderer, f, img)
    } else {
        draw_grid(window, renderer, g)
    }

    if bar {
        draw_bar(window, renderer, g, f, focus_mode, font)
    }
}

handle_event :: proc(ev: ^sdl.Event, focus_mode: ^bool, bar_enabled: ^bool, focus_state: ^Focus_State, grid: ^Grid) -> bool {
    #partial switch ev.type {
    case .KEY_DOWN:
        switch ev.key.key {
        case sdl.K_Q:
            return true
        case sdl.K_J:
            if focus_mode^ {
                focus_state.panned_y -= PAN_SPEED
            } else {
                grid_select_next(grid, grid.n_cols)
            }
        case sdl.K_K:
            if focus_mode^ {
                focus_state.panned_y += PAN_SPEED
            } else {
                grid_select_prev(grid, grid.n_cols)
            }
        case sdl.K_L:
            if focus_mode^ {
                focus_state.panned_x -= PAN_SPEED
            } else {
                grid_select_next(grid, 1)
            }
        case sdl.K_H:
            if focus_mode^ {
                focus_state.panned_x += PAN_SPEED
            }
            else {
                grid_select_prev(grid, 1)
            }
        case sdl.K_RETURN:
            if grid_selected_image(grid).thumbnail != nil {
                focus_mode^ = !focus_mode^
            }
        case sdl.K_B:
            bar_enabled^ = !bar_enabled^
        case sdl.K_EQUALS:
            if focus_mode^ {
                focus_state.zoom_idx = min(focus_state.zoom_idx+1, len(ZOOM_LEVELS)-1)
            } else {
                // TODO: use levels for thumbnails as well
                grid.thumb = min(grid.thumb+10, MAX_THUMB)
            }
        case sdl.K_MINUS:
            if focus_mode^ {
                focus_state.zoom_idx = max(focus_state.zoom_idx-1, 0)
            } else {
                grid.thumb = max(grid.thumb-10, MIN_THUMB)
            }
        }
    case .QUIT:
        return true
    }

    return false
}

run :: proc() -> (sdl_ok: bool, err: os.Error) {
    if len(os.args) < 2 {
        fmt.fprintln(os.stderr, "imgc: wrong number of arguments")
        return
    }

    // collect files. walk dirs
    sdl_ok = true
    images: [dynamic]Image
    defer {
        for img in images {
            if img.thumbnail != nil {
                sdl.DestroyTexture(img.thumbnail)
            }
            // if img.full != nil {
            //     sdl.DestroyTexture(img.full)
            // }
        }
        delete(images)
    }

    for arg in os.args[1:] {
        img := Image{}
        info, err1 := os.stat(arg, context.temp_allocator)
        if err1 == .Not_Exist {
            fmt.printf("%s: No such file or directory\n", arg)
            continue
        }
        if info.type == .Directory {
            dir := os.open(info.fullpath) or_return
            infos := os.read_dir(dir, 0, context.allocator) or_return
            for fi in infos {
                // no recursion
                if fi.type != .Directory {
                    img.file = fi
                    append(&images, img) or_return
                }
            }
        } else {
            img.file = info
            append(&images, img) or_return
        }
    }

    if len(images) == 0 {
        fmt.println("no valid paths given. exiting...")
        return true, nil
    }

    if !sdl.Init({.VIDEO}) {
        return false, nil
    }
    defer sdl.Quit()

    window: ^sdl.Window
    renderer: ^sdl.Renderer
    ok := sdl.CreateWindowAndRenderer("imgc", 800, 600, {.RESIZABLE}, &window, &renderer)
    if !ok {
        return false, nil
    }
    defer sdl.DestroyWindow(window);
    defer sdl.DestroyRenderer(renderer);

    if !sdl_ttf.Init() {
        return false, nil
    }
    defer sdl_ttf.Quit()

    font := sdl_ttf.OpenFont("/usr/share/fonts/TTF/DejaVuSans.ttf", 16)
    if font == nil {
        return false, nil
    }
    defer sdl_ttf.CloseFont(font)

    sdl_ok = true
    strings.builder_init(&g_builder) or_return
    defer strings.builder_destroy(&g_builder)

    grid := Grid{
        images = images,
        thumb = 120,
    }

    focus_state := Focus_State{
        zoom_idx = DEFAULT_ZOOM_LEVEL
    }
    defer if focus_state.texture != nil {
        sdl.DestroyTexture(focus_state.texture)
    }

    focus_mode: bool
    bar_enabled := true
    quit := false

    REDRAW_INTERVAL :: 200
    last_redraw := sdl.GetTicks() - REDRAW_INTERVAL
    for !quit {
        ev: sdl.Event
        redraw := false

        for sdl.PollEvent(&ev) {
            quit = quit || handle_event(&ev, &focus_mode, &bar_enabled, &focus_state, &grid)
            redraw = true
        }

        if !redraw {
            for !grid_are_all_loaded(&grid) {
                if !grid_load_next_img(&grid, renderer) {
                    ordered_remove(&grid.images, grid.n_loaded)
                }
                if sdl.GetTicks() - last_redraw >= REDRAW_INTERVAL {
                    break
                }
            }
            redraw = true
        }

        if grid_are_all_loaded(&grid) && !redraw {
            if !redraw && sdl.WaitEvent(&ev) {
                quit = quit || handle_event(&ev, &focus_mode, &bar_enabled, &focus_state, &grid)
                redraw = true
                for sdl.PollEvent(&ev) {
                    quit = quit || handle_event(&ev, &focus_mode, &bar_enabled, &focus_state, &grid)
                }
            }
        }

        now := sdl.GetTicks()
        if redraw || now - last_redraw >= REDRAW_INTERVAL {
            draw(window, renderer, bar_enabled, focus_mode, &grid, &focus_state, font)
            sdl.RenderPresent(renderer)
            last_redraw = now
        }
    }

    return true, nil
}

main :: proc() {
    sdl_ok, err := run()
    if !sdl_ok {
        fmt.fprintln(os.stderr, string(sdl.GetError()))
        os.exit(1)
    } else if err != nil {
        fmt.fprintln(os.stderr, err)
        os.exit(1)
    }
}
