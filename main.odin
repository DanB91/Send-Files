#+feature dynamic-literals
package main

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:math/rand"
import "core:nbio"
import "core:os"
import "core:prof/spall"
import "core:sync"
import "core:thread"
import "vendor:microui"
import "vendor:sdl3"

INITIAL_WINDOW_WIDTH :: 600
INITIAL_WINDOW_HEIGHT :: 600
FONT_MULTIPLIER :: 1

ENABLE_PROFILING :: false

main :: proc() {
	lane_count := os.get_processor_core_count()
	g := new(G)
	bootstrap_barrier: sync.Barrier
	sync.barrier_init(&bootstrap_barrier, lane_count)

	temp_tls: TLS
	temp_tls.g = g
	temp_tls.lane_count = lane_count
	temp_tls.barrier = &bootstrap_barrier

	if ENABLE_PROFILING {
		g.spall_ctx = spall.context_create("trace_test.spall")
	}


	threads := make([]^thread.Thread, lane_count - 1)
	spall_buffers := make([]^spall.Buffer, lane_count - 1)
	for i in 1 ..< lane_count {
		temp_tls.lane_id = i
		temp_tls.g = g

		if ENABLE_PROFILING {
			buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
			// defer delete(buffer_backing)
			temp_tls.spall_buffer = new(spall.Buffer)
			temp_tls.spall_buffer^ = spall.buffer_create(buffer_backing, u32(i))

			spall_buffers[i - 1] = temp_tls.spall_buffer
		}
		threads[i - 1] = thread.create_and_start_with_poly_data(temp_tls, multithread_entry_point)
	}


	temp_tls.lane_id = 0 //lane id 0 is always main thread

	if ENABLE_PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		temp_tls.spall_buffer = new(spall.Buffer)
		temp_tls.spall_buffer^ = spall.buffer_create(buffer_backing, 0)
	}

	multithread_entry_point(temp_tls)

	thread.join_multiple(..threads)
	for buffer in spall_buffers {
		spall.buffer_destroy(&g.spall_ctx, buffer)
	}
	if ENABLE_PROFILING {
		spall.buffer_destroy(&g.spall_ctx, temp_tls.spall_buffer)


		spall.context_destroy(&g.spall_ctx)
	}
}

multithread_entry_point :: proc(tls_context: TLS) {

	tls = tls_context
	g := tls.g


	if is_main_thread() {

		//initialize SDL3
		success := sdl3.Init({.VIDEO, .EVENTS})
		ensure(success)
		g.window_width = INITIAL_WINDOW_WIDTH
		g.window_height = INITIAL_WINDOW_HEIGHT
		g.window = sdl3.CreateWindow("Send Files", g.window_width, g.window_height, {.RESIZABLE})
		ensure(g.window != nil)
		g.renderer = sdl3.CreateRenderer(g.window, nil)
		ensure(g.renderer != nil)

		init_micro_context(g)
		init_microui_atlas()

		//init placeholder values.  TODO: remove
		append(&g.contacts, Contact{"Alice", "98765"})
		append(&g.contacts, Contact{"Bob", "654321"})
	}
	lane_sync()

	if is_main_thread() {
		context.allocator = context.temp_allocator
		run_ui()
	} else {
		//TODO
	}
	lane_sync()


}
build_gui :: proc(g: ^G) {
	mu_textf :: proc(ctx: ^microui.Context, f: string, args: ..any) {
		text := fmt.tprintf(f, ..args)
		microui.text(ctx, text)
	}
	mu_ctx := &g.microui_context
	microui.begin(mu_ctx)
	rect := microui.Rect{0, 0, g.window_width, g.window_height}
	if microui.window(mu_ctx, "Send Files", rect, {.NO_RESIZE, .NO_CLOSE, .NO_TITLE}) {
		microui.layout_row(mu_ctx, {0, 0, 0})
		mu_textf(mu_ctx, "Name and Address: Dan <123456>")
		if .SUBMIT in microui.button(mu_ctx, "Copy Address") {
			microui.open_popup(mu_ctx, "Edit Your Info")
		}
		if .SUBMIT in microui.button(mu_ctx, "Edit") {
			microui.open_popup(mu_ctx, "Edit Your Info")
		}
		if microui.popup(mu_ctx, "Edit Your Info") {
			//TODO delete
			@(static) buf: [32]u8
			@(static) textlen: int

			microui.layout_row(mu_ctx, {0, 0})
			microui.label(mu_ctx, "Name:")
			microui.textbox(mu_ctx, buf[:], &textlen)
			microui.label(mu_ctx, "Address:")
			if .SUBMIT in microui.button(mu_ctx, "Regenerate Address") {
			}
		}
		if .ACTIVE in microui.treenode(mu_ctx, "Contacts", {.EXPANDED}) {
			microui.layout_row(mu_ctx, {0, 0})
			if microui.layout_column(mu_ctx) {
				microui.button(mu_ctx, "Name ")
				for contact in g.contacts {
					mu_textf(mu_ctx, "%v<%v>", contact.name, contact.public_key)
				}
			}
			if microui.layout_column(mu_ctx) {
				microui.label(mu_ctx, "Actions")
				microui.layout_row(mu_ctx, {0, 0})
				for contact in g.contacts {
					if .SUBMIT in microui.button(mu_ctx, "Send File") {

					}
					if .SUBMIT in microui.button(mu_ctx, "Delete") {

					}
				}
			}
			microui.layout_row(mu_ctx, {-1})
			if .SUBMIT in microui.button(mu_ctx, "Add Contact") {

			}

		}
	}
	microui.end(mu_ctx)

}


run_ui :: proc() {
	g := tls.g

	last_frame: sdl3.Time
	assert(sdl3.GetCurrentTime(&last_frame))
	for !g.should_quit {
		if ENABLE_PROFILING {
			spall.SCOPED_EVENT(&g.spall_ctx, tls.spall_buffer, "frame")
		}

		free_all(context.temp_allocator)
		now: sdl3.Time
		assert(sdl3.GetCurrentTime(&now))
		dt := now - last_frame
		last_frame = now
		if is_main_thread() {
			e: sdl3.Event
			for sdl3.PollEvent(&e) {
				#partial switch e.type {
				case .QUIT:
					g.should_quit = true
				case .MOUSE_BUTTON_DOWN:
					button: Maybe(microui.Mouse)

					switch e.button.button {
					case sdl3.BUTTON_LEFT:
						button = .LEFT
					case sdl3.BUTTON_RIGHT:
						button = .RIGHT
					case sdl3.BUTTON_MIDDLE:
						button = .MIDDLE
					}
					switch b in button {
					case microui.Mouse:
						microui.input_mouse_down(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							b,
						)
					}
				case .MOUSE_BUTTON_UP:
					button: Maybe(microui.Mouse)

					switch e.button.button {
					case sdl3.BUTTON_LEFT:
						button = .LEFT
					case sdl3.BUTTON_RIGHT:
						button = .RIGHT
					case sdl3.BUTTON_MIDDLE:
						button = .MIDDLE
					}
					switch b in button {
					case microui.Mouse:
						microui.input_mouse_up(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							b,
						)
					}
				case .MOUSE_MOTION:
					microui.input_mouse_move(
						&g.microui_context,
						auto_cast e.motion.x,
						auto_cast e.motion.y,
					)
				case .WINDOW_RESIZED:
					g.window_width = e.window.data1
					g.window_height = e.window.data2
					init_micro_context(g)

				}
			}

		}

		build_gui(g)

		sdl3.RenderClear(g.renderer)
		cmd: ^microui.Command
		for microui.next_command(&g.microui_context, &cmd) {
			switch v in cmd.variant {
			case ^microui.Command_Text:
				render_text(v.font, v.str, v.pos.x, v.pos.y, v.color)
			case ^microui.Command_Clip:
				mu_rect := v.rect
				sdl_rect := sdl3.Rect{mu_rect.x, mu_rect.y, mu_rect.w, mu_rect.h}
				assert(sdl3.SetRenderClipRect(g.renderer, &sdl_rect))
			case ^microui.Command_Rect:
				mu_rect := v.rect
				sdl_rect := sdl3.FRect {
					auto_cast mu_rect.x,
					auto_cast mu_rect.y,
					auto_cast mu_rect.w,
					auto_cast mu_rect.h,
				}
				color := v.color
				sdl3.SetRenderDrawColor(g.renderer, 0, 0, 0, 0)
				sdl3.RenderRect(g.renderer, &sdl_rect)
				sdl3.SetRenderDrawColor(g.renderer, color.r, color.g, color.b, color.a)
				sdl3.RenderFillRect(g.renderer, &sdl_rect)
			case ^microui.Command_Icon:
				render_icon(v.id, v.rect, v.color)
			case ^microui.Command_Jump:
			//do nothing?
			}
		}

		sdl3.RenderPresent(g.renderer)
	}
}

is_main_thread :: proc() -> bool {
	return lane_id() == 0
}
lane_id :: proc() -> int {
	return tls.lane_id
}
lane_count :: proc() -> int {
	return tls.lane_count
}
lane_sync :: proc() {
	sync.barrier_wait(tls.barrier)
}
lane_range :: proc(count: int) -> (start: int, end: int) {
	lane_count := lane_count()
	lane_id := lane_id()

	values_per_thread := count / lane_count
	leftover_values_count := count % lane_count
	thread_has_leftover := lane_id < leftover_values_count
	leftovers_before_this_thread_idx := lane_id if thread_has_leftover else leftover_values_count

	start = values_per_thread * lane_id + leftovers_before_this_thread_idx
	end = start + values_per_thread + (1 if thread_has_leftover else 0)
	return
}
init_micro_context :: proc(g: ^G) {
	microui.init(&g.microui_context)

	g.microui_context.text_height = proc(font: microui.Font) -> i32 {
		return microui.default_atlas_text_height(font) * FONT_MULTIPLIER
	}

	g.microui_context.text_width = proc(font: microui.Font, text: string) -> i32 {
		return microui.default_atlas_text_width(font, text) * FONT_MULTIPLIER
	}
	//needed to have longer text on the same line
	g.microui_context.style.size[0] = 200

}

init_microui_atlas :: proc() {
	g := tls.g
	// microui's atlas is a 128x128 single-channel (alpha) image.
	// Expand it to RGBA so SDL can use it: white RGB, atlas value as alpha.
	pixels := make(
		[]u32,
		microui.DEFAULT_ATLAS_WIDTH * microui.DEFAULT_ATLAS_HEIGHT,
		context.temp_allocator,
	)

	for val, i in microui.default_atlas_alpha {
		pixels[i] = 0x00FFFFFF | (u32(val) << 24) // ABGR: alpha from atlas, white RGB
	}

	g.atlas_texture = sdl3.CreateTexture(
		g.renderer,
		.ABGR8888,
		.STATIC,
		microui.DEFAULT_ATLAS_WIDTH,
		microui.DEFAULT_ATLAS_HEIGHT,
	)
	assert(g.atlas_texture != nil)

	sdl3.UpdateTexture(
		g.atlas_texture,
		nil,
		raw_data(pixels),
		microui.DEFAULT_ATLAS_WIDTH * size_of(u32),
	)
	sdl3.SetTextureBlendMode(g.atlas_texture, {.BLEND})
	sdl3.SetTextureScaleMode(g.atlas_texture, .NEAREST)
}
render_text :: proc(font: microui.Font, text: string, x, y: i32, color: microui.Color) {
	g := tls.g
	sdl3.SetTextureColorMod(g.atlas_texture, color.r, color.g, color.b)
	sdl3.SetTextureAlphaMod(g.atlas_texture, color.a)

	dst_x := f32(x)
	dst_y := f32(y)

	for ch in text {
		// Clamp to the atlas range; microui's default atlas covers glyphs 32–127
		glyph := int(ch)
		if glyph < 32 || glyph > 127 do glyph = 127

		atlas_rect := microui.default_atlas[microui.DEFAULT_ATLAS_FONT + glyph]

		src := sdl3.FRect {
			x = f32(atlas_rect.x),
			y = f32(atlas_rect.y),
			w = f32(atlas_rect.w),
			h = f32(atlas_rect.h),
		}
		dst := sdl3.FRect {
			x = dst_x,
			y = dst_y,
			w = src.w * FONT_MULTIPLIER,
			h = src.h * FONT_MULTIPLIER,
		}

		sdl3.RenderTexture(g.renderer, g.atlas_texture, &src, &dst)
		dst_x += dst.w
	}
}
render_icon :: proc(id: microui.Icon, rect: microui.Rect, color: microui.Color) {
	g := tls.g
	atlas_rect := microui.default_atlas[int(id)]

	// Center the icon glyph within the destination rect
	dst_x := f32(rect.x) + f32(rect.w - atlas_rect.w) / 2
	dst_y := f32(rect.y) + f32(rect.h - atlas_rect.h) / 2

	src := sdl3.FRect {
		x = f32(atlas_rect.x),
		y = f32(atlas_rect.y),
		w = f32(atlas_rect.w),
		h = f32(atlas_rect.h),
	}
	dst := sdl3.FRect {
		x = dst_x,
		y = dst_y,
		w = src.w,
		h = src.h,
	}

	sdl3.SetTextureColorMod(g.atlas_texture, color.r, color.g, color.b)
	sdl3.SetTextureAlphaMod(g.atlas_texture, color.a)
	sdl3.RenderTexture(g.renderer, g.atlas_texture, &src, &dst)
}


// Automatic profiling of every procedure:

@(instrumentation_enter)
spall_enter :: proc "contextless" (
	proc_address, call_site_return_address: rawptr,
	loc: runtime.Source_Code_Location,
) {

	if ENABLE_PROFILING {
		g := tls.g
		if g != nil {
			spall._buffer_begin(&g.spall_ctx, tls.spall_buffer, "", "", loc)
		}
	}
}

@(instrumentation_exit)
spall_exit :: proc "contextless" (
	proc_address, call_site_return_address: rawptr,
	loc: runtime.Source_Code_Location,
) {
	if ENABLE_PROFILING {
		g := tls.g
		if g != nil {
			spall._buffer_end(&g.spall_ctx, tls.spall_buffer)
		}
	}
}

@(thread_local)
tls: TLS

G :: struct {
	should_quit:     bool,
	spall_ctx:       spall.Context,
	window_width:    i32,
	window_height:   i32,


	//UI
	microui_context: microui.Context,

	//Persistent State
	contacts:        [dynamic]Contact,


	//platform specific
	window:          ^sdl3.Window,
	atlas_texture:   ^sdl3.Texture,
	renderer:        ^sdl3.Renderer,
}
Contact :: struct {
	name:       string,
	public_key: string, //TODO: make real public key
}
TLS :: struct {
	g:            ^G,
	lane_id:      int,
	lane_count:   int,
	barrier:      ^sync.Barrier,
	spall_buffer: ^spall.Buffer,
}
