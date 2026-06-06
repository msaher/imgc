package main

import "core:c"
import "core:os"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import sdl_img "vendor:sdl3/image"

main :: proc() {
    if len(os.args) < 2 {
        fmt.fprintln(os.stderr, "imgc: wrong number of arguments")
        os.exit(1)
    }

    ok := sdl.Init({.VIDEO})
    assert(ok)
    defer sdl.Quit()

    window: ^sdl.Window
    renderer: ^sdl.Renderer
    ok = sdl.CreateWindowAndRenderer("hello", 800, 600, {.RESIZABLE}, &window, &renderer)
    assert(ok)
    defer sdl.DestroyWindow(window);
    defer sdl.DestroyRenderer(renderer);
    sdl.SetRenderVSync(renderer, 1)


    selected: int
    textures: [dynamic]^sdl.Texture
    for arg in os.args[1:] {
        img, err := strings.clone_to_cstring(arg)
        assert(err == nil)
        surface := sdl_img.Load(img)
        delete(img)
        if surface == nil {
            fmt.fprintf(os.stderr, "%s: %s \n", arg, sdl.GetError())
            return
        }
        defer sdl.DestroySurface(surface)
        texture := sdl.CreateTextureFromSurface(renderer, surface)
        if texture == nil {
            fmt.fprintf(os.stderr, "%s\n", sdl.GetError())
            return
        }
        append(&textures, texture)
    }

    defer for texture in textures {
        sdl.DestroyTexture(texture)
    }

    first_visible_row: int
    n_cols: int
    quit := false
    for !quit {
        ev: sdl.Event
        // handle events
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
            case .KEY_DOWN:
                switch ev.key.key {
                case sdl.K_Q:
                    quit = true
                case sdl.K_J:
                    selected = min(len(textures)-1, selected+n_cols)
                case sdl.K_K:
                    selected = max(0, selected-n_cols)
                case sdl.K_L:
                    selected = min(len(textures)-1, selected+1)
                case sdl.K_H:
                    selected = max(0, selected-1)
                }
            case .QUIT:
                quit = true
            }
        }

        // draw
        sdl.SetRenderDrawColor(renderer, 20, 20, 20, 255)
        sdl.RenderClear(renderer)

        // suppose thumb :: 200
        // (400x200) --> (200x100), scale = 0.5
        // (800x600) --> (200x150), scale = 0.25
        // max(tw*th)*scale = thumbnail = 200
        thumb :: 150
        gap :: 20

        ww, wh: c.int
        sdl.GetWindowSize(window, &ww, &wh)
        n_cols = int(ww/(thumb+gap))
        n_visible_rows := int(wh/(thumb+gap))
        if n_cols < 1 {
            n_cols = 1
        }

        // center grid
        grid_w := f32(n_cols * (thumb + gap) - gap)
        grid_h := f32(n_visible_rows * (thumb + gap) - gap)
        x_offset := (f32(ww) - grid_w) / 2
        y_offset := (f32(wh) - grid_h) / 2

        // determine scroll offset
        selected_row := selected / n_cols
        last_visible_row := first_visible_row + n_visible_rows - 1
        if selected_row > last_visible_row {
            first_visible_row += 1
        } else if selected_row < first_visible_row {
            first_visible_row -= 1
        }

        dst: sdl.FRect
        for t, i in textures {
            row := i / n_cols
            if row < first_visible_row || row > last_visible_row {
                continue
            }
            col := i % n_cols

            tw, th: f32
            sdl.GetTextureSize(t, &tw, &th)
            scale := min(f32(thumb) / tw, f32(thumb) / th)
            dst.w = tw*scale
            dst.h = th*scale

            dst.x = x_offset + f32(col)*(thumb+gap) + (thumb - dst.w)/2
            dst.y = y_offset + f32(row)*(thumb+gap) + (thumb - dst.h)/2 - f32(first_visible_row)*(thumb+gap)

            // draw a box
            if i == selected {
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

            sdl.RenderTexture(renderer, t, nil, &dst)
        }

        sdl.RenderPresent(renderer)
    }
}
