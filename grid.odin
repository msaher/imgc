package main

import "core:fmt"
import "core:os"

import "imlib"

import sdl "vendor:sdl3"

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


