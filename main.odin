package main

import "core:c"
import "core:os"
import "core:fmt"
import "core:strings"
import "base:runtime"
import sdl "vendor:sdl3"
import sdl_img "vendor:sdl3/image"
import sdl_ttf "vendor:sdl3/ttf"

run :: proc() -> (sdl_ok: bool, err: os.Error) {
    if len(os.args) < 2 {
        fmt.fprintln(os.stderr, "imgc: wrong number of arguments")
        return
    }

    if !sdl.Init({.VIDEO}) {
        return false, nil
    }
    defer sdl.Quit()

    window: ^sdl.Window
    renderer: ^sdl.Renderer
    ok := sdl.CreateWindowAndRenderer("hello", 800, 600, {.RESIZABLE}, &window, &renderer)
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

    selected: int
    textures: [dynamic]^sdl.Texture
    for arg in os.args[1:] {
        carg := strings.clone_to_cstring(arg) or_return
        defer delete(carg)

        surface := sdl_img.Load(carg)
        if surface == nil {
            return false, nil
        }
        defer sdl.DestroySurface(surface)
        texture := sdl.CreateTextureFromSurface(renderer, surface)
        if texture == nil {
            return false, nil
        }
        append(&textures, texture)
    }

    defer for texture in textures {
        sdl.DestroyTexture(texture)
    }

    focus: bool
    draw_bar := true
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
                case sdl.K_RETURN:
                    focus = !focus
                case sdl.K_B:
                    draw_bar = !draw_bar
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

        if focus {
            t := textures[selected]
            tw, th: f32
            sdl.GetTextureSize(t, &tw, &th)
            scale := min(f32(ww)/tw, f32(wh)/th)
            if scale > 1 {
                scale = 1
            }
            dst := sdl.FRect {
                w = scale*tw,
                h = scale*th,
                x = f32(ww)/2 - (tw*scale)/2,
                y = f32(wh)/2 - (th*scale)/2,
            }
            sdl.RenderTexture(renderer, t, nil, &dst)
        } else {
            // suppose thumb :: 200
            // (400x200) --> (200x100), scale = 0.5
            // (800x600) --> (200x150), scale = 0.25
            // max(tw*th)*scale = thumbnail = 200
            thumb :: 120
            gap :: 20

            n_cols = int(ww/(thumb+gap))
            n_visible_rows := int(wh/(thumb+gap))
            if n_cols < 1 {
                n_cols = 1
            }

            // center grid
            grid_w := f32(n_cols * (thumb + gap) - gap)
            // grid_h := f32(n_visible_rows * (thumb + gap)-2*gap)
            x_offset := (f32(ww) - grid_w) / 2
            // y_offset := (f32(wh) - grid_h) / 2
            y_offset: f32 = 50

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
        }

        // setup text
        if draw_bar {
            filename := os.args[selected+1]
            cfilename := strings.unsafe_string_to_cstring(filename)

            surface := sdl_ttf.RenderText_Blended(font, cfilename, len(filename), sdl.Color{255, 255, 255, 255})
            text_left := sdl.CreateTextureFromSurface(renderer, surface)
            sdl.DestroySurface(surface)
            defer sdl.DestroyTexture(text_left)

            strings.builder_reset(&builder)
            strings.write_int(&builder, selected+1)
            strings.write_byte(&builder, '/')
            strings.write_int(&builder, len(textures))
            counter := strings.to_string(builder)
            ccounter := strings.unsafe_string_to_cstring(counter)
            surface = sdl_ttf.RenderText_Blended(font, ccounter, len(counter), sdl.Color{255, 255, 255, 255})
            text_right := sdl.CreateTextureFromSurface(renderer, surface)
            sdl.DestroySurface(surface)
            defer sdl.DestroyTexture(text_right)

            tw, th: f32
            sdl.GetTextureSize(text_left, &tw, &th)

            // draw bar
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
