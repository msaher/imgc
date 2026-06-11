package main

import "base:runtime"
import "core:c"
import "core:os"
import "core:fmt"
import "core:strings"

import "imlib"

import sdl "vendor:sdl3"
import sdl_ttf "vendor:sdl3/ttf"

// TODO: store file path also as given by argv instead of full
// path
Image :: struct {
    thumbnail: ^sdl.Texture,
    file: os.File_Info,
}

PAN_SPEED :: 100
ZOOM_LEVELS := []f32{0.12, 0.25, 0.50, 0.75, 1.00, 1.50, 2.00, 4.00, 8.00}
DEFAULT_ZOOM_LEVEL :: 4

Focus_State :: struct {
    panned_x: f32,
    panned_y: f32,
    zoom_idx: int,
    img: Image,
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

grid_selected_image :: proc(g: ^Grid) -> Image {
    return g.images[g.selected]
}

grid_select_next :: proc(g: ^Grid, i: int) {
    g.selected = clamp(g.selected+i, 0, len(g.images)-1)
}

grid_select_prev :: proc(g: ^Grid, i: int) {
    grid_select_next(g, -i)
}

grid_load_next_img :: proc(g: ^Grid, renderer: ^sdl.Renderer, builder: ^strings.Builder) -> bool {
    idx := g.n_loaded
    img := &g.images[idx]
    strings.builder_reset(builder)
    strings.write_string(builder, img.file.fullpath)
    cpath := strings.to_cstring(builder)

    im := imlib.load_image(cpath)
    if im == nil {
        fmt.fprintf(os.stderr, "%s: %d\n", cpath, imlib.get_error())
        return false
    }

    // scale image down
    im = img_scale_down(im, MAX_THUMB)
    if im == nil {
        fmt.fprintf(os.stderr, "%s: failed to scale image: %d\n", cpath, imlib.get_error())
        return false
    }
    imlib.context_set_image(im)

    // create texture... make maybe proc
    w := imlib.image_get_width()
    h := imlib.image_get_height()
    pixels := imlib.image_get_data_for_reading_only()
    thumbnail := sdl.CreateTexture(renderer, .ARGB8888, .STATIC, w, h)
    ok := sdl.UpdateTexture(thumbnail, nil, rawptr(pixels), w * size_of(c.uint32_t))

    if !ok {
        fmt.fprintf(os.stderr, "%s: texture error: %s\n", cpath, sdl.GetError())
        return false
    }

    img.thumbnail = thumbnail

    // do we really need to do this?
    imlib.free_image() // free scaled image

    g.n_loaded += 1
    return true
}

img_scale_down :: proc(im: imlib.Image, thumb: f32) -> imlib.Image {
    imlib.context_set_image(im)
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
        return im_scaled
    }
    return im
}

image_load_as_texture :: proc(renderer: ^sdl.Renderer, img: Image) -> (^sdl.Texture, bool) {
    // TODO: use builder
    cpath := strings.clone_to_cstring(img.file.fullpath)
    defer delete(cpath)
    im := imlib.load_image(cpath)
    if im == nil {
        return nil, false
    }
    t, ok := create_texture_from_im(renderer, im)
    return t, ok
}

create_texture_from_im :: proc(renderer: ^sdl.Renderer, im: imlib.Image) -> (^sdl.Texture, bool) {
    imlib.context_set_image(im)
    w := imlib.image_get_width()
    h := imlib.image_get_height()
    pixels := imlib.image_get_data_for_reading_only()
    if pixels == nil {
        return nil, false
    }

    t := sdl.CreateTexture(renderer, .ARGB8888, .STATIC, w, h)
    if t == nil {
        return nil, false
    }

    ok := sdl.UpdateTexture(t, nil, rawptr(pixels), w * size_of(c.uint32_t))
    return t, ok
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

draw_focus :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, fc: ^Focus_State, img: Image) {
    // set image... maybe make proc
    if fc.img != img {
        if fc.texture != nil {
            sdl.DestroyTexture(fc.texture)
        }
        t, ok := image_load_as_texture(renderer, img)
        fc.texture = t
        if !ok {
            return
        }
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

draw_bar :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, builder: ^strings.Builder, grid: ^Grid, focus_state: ^Focus_State, focus_mode: bool, font: ^sdl_ttf.Font) {

    filename := grid_selected_image(grid).file.fullpath
    cfilename := strings.unsafe_string_to_cstring(filename)

    surface := sdl_ttf.RenderText_Blended(font, cfilename, len(filename), sdl.Color{255, 255, 255, 255})
    text_left := sdl.CreateTextureFromSurface(renderer, surface)
    sdl.DestroySurface(surface)
    defer sdl.DestroyTexture(text_left)

    strings.builder_reset(builder)
    if focus_mode {
        strings.write_int(builder, int(ZOOM_LEVELS[focus_state.zoom_idx]*100))
        strings.write_string(builder, "% ")
    }
    // abstract this
    strings.write_int(builder, grid.selected+1)
    strings.write_byte(builder, '/')
    strings.write_int(builder, len(grid.images))
    counter := strings.to_string(builder^)
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

run :: proc() -> (sdl_ok: bool, err: os.Error) {
    if len(os.args) < 2 {
        fmt.fprintln(os.stderr, "imgc: wrong number of arguments")
        return
    }

    // collect files. walk dirs
    // TODO: store infos instead of paths?
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

    if !sdl.SetRenderVSync(renderer, 1) {
        return false, nil
    }

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
    builder: strings.Builder
    strings.builder_init(&builder) or_return
    defer strings.builder_destroy(&builder)

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

    freq := sdl.GetPerformanceFrequency()
    for !quit {
        start := sdl.GetPerformanceCounter()
        budget := u64(f64(freq) * 0.002) // 2ms

        // handle events
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
            case .KEY_DOWN:
                switch ev.key.key {
                case sdl.K_Q:
                    quit = true
                case sdl.K_J:
                    if focus_mode {
                        focus_state.panned_y -= PAN_SPEED
                    } else {
                        grid_select_next(&grid, grid.n_cols)
                    }
                case sdl.K_K:
                    if focus_mode {
                        focus_state.panned_y += PAN_SPEED
                    } else {
                        grid_select_prev(&grid, grid.n_cols)
                    }
                case sdl.K_L:
                    if focus_mode {
                        focus_state.panned_x -= PAN_SPEED
                    } else {
                        grid_select_next(&grid, 1)
                    }
                case sdl.K_H:
                    if focus_mode {
                        focus_state.panned_x += PAN_SPEED
                    }
                    else {
                        grid_select_prev(&grid, 1)
                    }
                case sdl.K_RETURN:
                    if grid_selected_image(&grid).thumbnail != nil {
                        focus_mode = !focus_mode
                    }
                case sdl.K_B:
                    bar_enabled = !bar_enabled
                case sdl.K_EQUALS:
                    if focus_mode {
                        focus_state.zoom_idx = min(focus_state.zoom_idx+1, len(ZOOM_LEVELS)-1)
                    } else {
                        // TODO: use levels for thumbnails as well
                        grid.thumb = min(grid.thumb+10, MAX_THUMB)
                    }
                case sdl.K_MINUS:
                    if focus_mode {
                        focus_state.zoom_idx = max(focus_state.zoom_idx-1, 0)
                    } else {
                        grid.thumb = max(grid.thumb-10, MIN_THUMB)
                    }
                }
            case .QUIT:
                quit = true
            }
        }

        for !grid_are_all_loaded(&grid) {
            if !grid_load_next_img(&grid, renderer, &builder) {
                ordered_remove(&grid.images, grid.n_loaded)
            }

            if sdl.HasEvents(.FIRST, .LAST) {
                break
            }
            now := sdl.GetPerformanceCounter()
            if (now - start) > budget {
                break
            }
        }

        // draw
        sdl.SetRenderDrawColor(renderer, 20, 20, 20, 255)
        sdl.RenderClear(renderer)

        ww, wh: c.int
        sdl.GetWindowSize(window, &ww, &wh)

        if focus_mode {
            draw_focus(window, renderer, &focus_state, grid_selected_image(&grid))
        } else {
            draw_grid(window, renderer, &grid)
        }
        sdl.GetWindowSize(window, &ww, &wh)

        // setup text
        if bar_enabled {
            draw_bar(window, renderer, &builder, &grid, &focus_state, focus_mode, font)
        }

        sdl.RenderPresent(renderer)
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
