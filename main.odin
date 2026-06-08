package main

import "core:c"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:time"
import "base:runtime"
import sdl "vendor:sdl3"
import sdl_img "vendor:sdl3/image"
import sdl_ttf "vendor:sdl3/ttf"

PAN_SPEED :: 100
ZOOM_LEVELS := []f32{0.12, 0.25, 0.50, 0.75, 1.00, 1.50, 2.00, 4.00, 8.00}
DEFAULT_ZOOM_LEVEL :: 4

Focus_State :: struct {
    panned_x: f32,
    panned_y: f32,
    zoom_idx: int
}

MAX_THUMB :: 500
MIN_THUMB :: 10

Grid_State :: struct {
    paths: [dynamic]string,
    textures: [dynamic]^sdl.Texture,
    load_len: int,
    selected: int,
    n_cols: int,
    thumb: f32,
    first_visible_row: int,
}

draw_focus :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, fc: ^Focus_State, t: ^sdl.Texture) {
    ww, wh: c.int
    sdl.GetWindowSize(window, &ww, &wh)

    tw, th: f32
    sdl.GetTextureSize(t, &tw, &th)
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

    sdl.RenderTexture(renderer, t, nil, &dst)
}

draw_grid :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, grid: ^Grid_State) {
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

    total_rows := (len(grid.textures) + grid.n_cols - 1) / grid.n_cols
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
    for t, i in grid.textures {
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
            for i in 0..<thickness {
                r := sdl.FRect{
                    x = dst.x - f32(i),
                    y = dst.y - f32(i),
                    w = dst.w + f32(i)*2,
                    h = dst.h + f32(i)*2,
                }
                sdl.RenderRect(renderer, &r)
            }
        }

        if t != nil {
            sdl.RenderTexture(renderer, t, nil, &dst)
        }
    }
}

draw_bar :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, builder: ^strings.Builder, grid: ^Grid_State, focus_state: ^Focus_State, focus_mode: bool, font: ^sdl_ttf.Font) {
    filename := grid.paths[grid.selected]
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
    strings.write_int(builder, grid.selected+1)
    strings.write_byte(builder, '/')
    strings.write_int(builder, len(grid.textures))
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
    paths: [dynamic]string
    defer delete(paths)
    for arg in os.args[1:] {
        info, err := os.stat(arg, context.temp_allocator)
        if err == .Not_Exist {
            fmt.printf("%s: No such file or directory\n", arg)
            continue
        }
        if info.type == .Directory {
            dir := os.open(info.fullpath) or_return
            infos := os.read_dir(dir, 0, context.allocator) or_return
            for fi in infos {
                // no recursion
                if fi.type != .Directory {
                    append(&paths, fi.fullpath) or_return
                }
            }
        } else {
            append(&paths, info.fullpath) or_return
        }
    }

    if len(paths) == 0 {
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

    textures := make([dynamic]^sdl.Texture, len(paths))
    defer {
        for texture in textures {
            sdl.DestroyTexture(texture)
        }
        delete(textures)
    }

    grid := Grid_State{
        thumb = 120,
        textures = textures,
        paths = paths,
    }

    focus_state := Focus_State{
        zoom_idx = DEFAULT_ZOOM_LEVEL
    }

    focus_mode: bool
    bar_enabled := true
    quit := false

    freq  := sdl.GetPerformanceFrequency()
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
                        grid.selected = min(len(grid.textures)-1, grid.selected+grid.n_cols)
                    }
                case sdl.K_K:
                    if focus_mode {
                        focus_state.panned_y += PAN_SPEED
                    } else {
                        grid.selected = max(0, grid.selected-grid.n_cols)
                    }
                case sdl.K_L:
                    if focus_mode {
                        focus_state.panned_x -= PAN_SPEED
                    } else {
                        grid.selected = min(len(grid.textures)-1, grid.selected+1)
                    }
                case sdl.K_H:
                    if focus_mode {
                        focus_state.panned_x += PAN_SPEED
                    }
                    else {
                        grid.selected = max(0, grid.selected-1)
                    }
                case sdl.K_RETURN:
                    if grid.textures[grid.selected] != nil {
                        focus_mode = !focus_mode
                    }
                case sdl.K_B:
                    bar_enabled = !bar_enabled
                case sdl.K_EQUALS:
                    if focus_mode {
                        focus_state.zoom_idx = min(focus_state.zoom_idx+1, len(ZOOM_LEVELS)-1)
                    } else {
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

        // draw
        sdl.SetRenderDrawColor(renderer, 20, 20, 20, 255)
        sdl.RenderClear(renderer)

        ww, wh: c.int
        sdl.GetWindowSize(window, &ww, &wh)

        if focus_mode {
            draw_focus(window, renderer, &focus_state, grid.textures[grid.selected])
        } else {
            draw_grid(window, renderer, &grid)
        }
        sdl.GetWindowSize(window, &ww, &wh)

        // setup text
        if bar_enabled {
            draw_bar(window, renderer, &builder, &grid, &focus_state, focus_mode, font)
        }

        // load as many thumbnails as you can before end of frame
        for grid.load_len != len(paths) {
            now := sdl.GetPerformanceCounter()
            if (now - start) > budget {
                break
            }

            path := grid.paths[grid.load_len]
            strings.builder_reset(&builder)
            strings.write_string(&builder, path)
            cpath := strings.to_cstring(&builder) or_return

            t := sdl_img.LoadTexture(renderer, cpath)
            if t == nil {
                // skip it
                fmt.printf("%s: %s\n", path, sdl.GetError())
                ordered_remove(&grid.paths, grid.load_len)
                ordered_remove(&grid.textures, grid.load_len)
            } else {
                grid.textures[grid.load_len] = t
                grid.load_len += 1
            }
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
    }
}
