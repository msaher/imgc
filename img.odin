package main

import "core:fmt"
import "core:os"
import "core:c"

import "imlib"

import sdl "vendor:sdl3"

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
