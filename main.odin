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


    img, err := strings.clone_to_cstring(os.args[1])
    assert(err == nil)
    surface := sdl_img.Load(img)
    defer sdl.DestroySurface(surface)
    texture := sdl.CreateTextureFromSurface(renderer, surface)
    defer sdl.DestroyTexture(texture)

    quit := false
    for !quit {
        ev: sdl.Event
        // handle events
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
            case .KEY_DOWN:
                if ev.key.key == sdl.K_Q {
                    quit = true
                }
            case .QUIT:
                quit = true
            }
        }

        // draw
        sdl.SetRenderDrawColor(renderer, 20, 20, 20, 255)
        sdl.RenderClear(renderer)

        // center image within window
        dst: sdl.FRect
        ww, wh: c.int
        tw, th: f32
        sdl.GetWindowSize(window, &ww, &wh)
        sdl.GetTextureSize(texture, &tw, &th)
        if false {
            dst = sdl.FRect{
                w = tw,
                h = th,
                x = f32(ww)/2-tw/2,
                y = f32(wh)/2-th/2,
            }
        } else {
            thumb :: 200
            // (400x200) --> (200x100), scale = 0.5
            // (800x600) --> (200x150), scale = 0.25
            // max(tw*th)*scale = thumbnail = 200
            scale := thumb/max(tw, th)
            dst = sdl.FRect {
                w = tw*scale,
                h = th*scale,
                x = 0,
                y = 0,
            }
        }

        sdl.RenderTexture(renderer, texture, nil, &dst)

        sdl.RenderPresent(renderer)
    }
}
