package main

import "core:os"
import "core:fmt"
import "core:strings"

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
        had_input := false

        for sdl.PollEvent(&ev) {
            quit = quit || handle_event(&ev, &focus_mode, &bar_enabled, &focus_state, &grid)
            had_input = true
        }

        // load aggressively when idle of input
        if !had_input {
            for !grid_are_all_loaded(&grid) {
                if !grid_load_next_img(&grid, renderer) {
                    ordered_remove(&grid.images, grid.n_loaded)
                }

                if sdl.GetTicks() - last_redraw >= REDRAW_INTERVAL {
                    break
                }

                if sdl.HasEvents(.FIRST, .LAST) {
                    break
                }
            }
        }

        now := sdl.GetTicks()

        // redraw ONLY on timer or input, not after loading
        if had_input || now - last_redraw >= REDRAW_INTERVAL {
            draw(window, renderer, bar_enabled, focus_mode, &grid, &focus_state, font)
            sdl.RenderPresent(renderer)
            last_redraw = now
        }

        // idle block when fully done
        if grid_are_all_loaded(&grid) && !had_input {
            _ = sdl.WaitEvent(&ev)
            quit = quit || handle_event(&ev, &focus_mode, &bar_enabled, &focus_state, &grid)
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
