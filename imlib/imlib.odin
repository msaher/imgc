package imlib

import "core:c"
foreign import imlib "system:Imlib2"

Image :: rawptr

@(link_prefix="imlib_")
@(default_calling_convention="c")
foreign imlib {
    version :: proc() -> c.int ---

    load_image :: proc(file: cstring) -> Image ---

    context_set_image :: proc(image: Image) ---
    context_set_anti_alias :: proc(anti_alias: bool) ---

    free_image :: proc() ---
    free_image_and_decache :: proc() ---

    get_error :: proc() -> c.int ---

    image_get_data_for_reading_only :: proc() -> [^]c.uint32_t ---

    create_cropped_image :: proc(x, y, width, height: c.int) -> Image ---


    create_cropped_scaled_image :: proc(
        src_x, src_y,
        src_width, src_height,
        dst_width, dst_height: c.int
    ) -> Image ---

    image_get_width :: proc() -> c.int ---
    image_get_height :: proc() -> c.int ---

}
