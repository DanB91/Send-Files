#+feature dynamic-literals
package main

import im "3rdparty/imgui"
import "3rdparty/imgui/imgui_impl_sdl3"
import "3rdparty/imgui/imgui_impl_sdlgpu3"
import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:math/rand"
import "core:nbio"
import "core:os"
import "core:prof/spall"
import "core:strings"
import "core:sync"
import "core:thread"
import "vendor:sdl3"

INITIAL_WINDOW_WIDTH :: 800
INITIAL_WINDOW_HEIGHT :: 800
FONT_MULTIPLIER :: 1

ENABLE_PROFILING :: false
ENABLE_DOCKING :: false

main :: proc() {
	lane_count := os.get_processor_core_count()
	g := new(G)
	bootstrap_barrier: sync.Barrier
	sync.barrier_init(&bootstrap_barrier, lane_count)

	temp_tls: TLS
	temp_tls.g = g
	temp_tls.lane_count = lane_count
	temp_tls.barrier = &bootstrap_barrier

	when ENABLE_PROFILING {
		g.spall_ctx = spall.context_create("trace_test.spall")
	}


	threads := make([]^thread.Thread, lane_count - 1)
	spall_buffers := make([]^spall.Buffer, lane_count - 1)
	for i in 1 ..< lane_count {
		temp_tls.lane_id = i
		temp_tls.g = g

		when ENABLE_PROFILING {
			buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
			// defer delete(buffer_backing)
			temp_tls.spall_buffer = new(spall.Buffer)
			temp_tls.spall_buffer^ = spall.buffer_create(buffer_backing, u32(i))

			spall_buffers[i - 1] = temp_tls.spall_buffer
		}
		threads[i - 1] = thread.create_and_start_with_poly_data(temp_tls, multithread_entry_point)
	}


	temp_tls.lane_id = 0 //lane id 0 is always main thread

	when ENABLE_PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		temp_tls.spall_buffer = new(spall.Buffer)
		temp_tls.spall_buffer^ = spall.buffer_create(buffer_backing, 0)
	}

	multithread_entry_point(temp_tls)

	thread.join_multiple(..threads)
	when ENABLE_PROFILING {
		for buffer in spall_buffers {
			spall.buffer_destroy(&g.spall_ctx, buffer)
		}
		spall.buffer_destroy(&g.spall_ctx, temp_tls.spall_buffer)


		spall.context_destroy(&g.spall_ctx)
	}
}

multithread_entry_point :: proc(tls_context: TLS) {

	tls = tls_context
	g := tls.g


	if is_main_thread() {
		im.CHECKVERSION()
		im.CreateContext()
		g.im_io = im.GetIO()
		g.im_io.ConfigFlags += {.NavEnableKeyboard}
		g.im_io.IniFilename = nil
		when ENABLE_DOCKING {
			g.im_io.ConfigFlags += {.DockingEnable, .ViewportsEnable}
			style := im.GetStyle()
			style.WindowRounding = 0
			style.Colors[im.Col.WindowBg].w = 1
		}


		//initialize SDL3
		success := sdl3.Init({.VIDEO, .EVENTS})
		ensure(success)
		g.window_width = INITIAL_WINDOW_WIDTH
		g.window_height = INITIAL_WINDOW_HEIGHT
		g.window = sdl3.CreateWindow("Send Files", g.window_width, g.window_height, {.RESIZABLE})
		ensure(g.window != nil)
		g.gpu_device = sdl3.CreateGPUDevice({.SPIRV, .DXIL, .METALLIB}, false, nil)
		ensure(g.gpu_device != nil)
		success = sdl3.ClaimWindowForGPUDevice(g.gpu_device, g.window)
		ensure(success)
		success = sdl3.SetGPUSwapchainParameters(g.gpu_device, g.window, .SDR, .VSYNC)
		ensure(success)

		//init imgui
		imgui_impl_sdl3.InitForSDLGPU(g.window)
		init_info := imgui_impl_sdlgpu3.InitInfo {
			Device               = g.gpu_device,
			ColorTargetFormat    = sdl3.GetGPUSwapchainTextureFormat(g.gpu_device, g.window),
			MSAASamples          = ._1,
			PresentMode          = .VSYNC,
			SwapchainComposition = .SDR,
		}
		imgui_impl_sdlgpu3.Init(&init_info)


		//init placeholder values.  TODO: remove
		append(&g.contacts, Contact{"Alice", "98765"})
		append(&g.contacts, Contact{"Bob", "654321"})

		append(
			&g.transfers,
			Transfer {
				"Handmade Hero Episode 1.mp4",
				1234567890,
				Contact{"Bob", "654321"},
				.NotStarted,
				nil,
				0,
			},
		)
		append(
			&g.transfers,
			Transfer {
				"Handmade Hero Episode 2.mp4",
				1234567890,
				Contact{"Bob", "654321"},
				.NotStarted,
				nil,
				0,
			},
		)
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
	cstr :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s)
	}
	im.SetNextWindowPos({0, 0})
	im.SetNextWindowSize(g.im_io.DisplaySize)
	im.Begin("Main", nil, {.NoCollapse, .NoResize, .NoTitleBar})
	// im.SetWindowFontScale(2)
	{
		im.BeginChild("Your Contact Info", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("Your Contact Info")
		im.Text("Dan <123456>")
		im.SameLine()
		if im.Button("Copy") {

		}
		im.SameLine()
		if im.Button("Edit Name") {
		}
		im.EndChild()
	}
	{
		im.BeginChild("Contacts", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("Contacts")
		if im.BeginTable("Contacts", 4) {

			for contact, i in g.contacts {
				im.TableNextColumn()
				im.PushIDInt(auto_cast i)
				im.Text("%s<%s>", cstr(contact.name), cstr(contact.public_key))
				im.TableNextColumn()
				if im.Button("Send File") {

				}
				im.TableNextColumn()
				if im.Button("Copy") {

				}
				im.TableNextColumn()
				if im.Button("Delete") {

				}
				im.PopID()

			}
			im.EndTable()
		}
		@(static) filter_text_buffer: [128]u8
		im.InputText("Filter", cstring(raw_data(&filter_text_buffer)), len(filter_text_buffer))
		im.SameLine()
		button_width: f32 = 120.0
		im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - button_width)
		if im.Button("Add Contact", {button_width, 0}) {

		}
		im.EndChild()
	}
	{
		human_readable_file_size :: proc(size: int) -> cstring {
			result: cstring
			switch size {
			case 0 ..< 1000:
				result = fmt.ctprintf("%v bytes", size)
			case 1000 ..< 1_000_000:
				result = fmt.ctprintf("%.2f KB", f64(size) / 1000.0)
			case 1_000_000 ..< 1_000_000_000:
				result = fmt.ctprintf("%.2f MB", f64(size) / 1_000_000.0)
			case 1_000_000_000 ..< 1_000_000_000_000:
				result = fmt.ctprintf("%.2f GB", f64(size) / 1_000_000_000.0)
			case:
				result = fmt.ctprintf("%.2f TB", f64(size) / 1_000_000_000_000.0)
			}
			return result
		}
		im.BeginChild("File Transfers", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("File Transfers")
		if im.BeginTable("File Transfers", 7) {
			im.TableSetupColumn("File Name")
			im.TableSetupColumn("To/From")
			im.TableSetupColumn("Status")
			im.TableSetupColumn("Progress")
			im.TableSetupColumn("Size")
			im.TableSetupColumn("Rate")
			im.TableSetupColumn("Actions", {.NoSort})
			im.TableHeadersRow()
			for tr, i in g.transfers {
				im.PushIDInt(auto_cast i)

				im.TableNextColumn()
				im.Text("%s", cstr(tr.file_name))

				im.TableNextColumn()
				im.Text("%s<%s>", cstr(tr.counter_party.name), cstr(tr.counter_party.public_key))

				im.TableNextColumn()
				status_str, _ := fmt.enum_value_to_string(tr.status)
				im.Text("%s", cstr(status_str))

				im.TableNextColumn()
				im.Text("%s", human_readable_file_size(0))

				im.TableNextColumn()
				im.Text("%s", human_readable_file_size(tr.file_size))

				im.TableNextColumn()
				im.Text("%.2f%", tr.rate / 100)

				im.TableNextColumn()
				if im.Button("Cancel") {}


				im.PopID()
			}

			im.EndTable()
		}
		@(static) filter_text_buffer: [128]u8
		im.InputText("Filter", cstring(raw_data(&filter_text_buffer)), len(filter_text_buffer))
		im.EndChild()

	}


	im.End()

}


run_ui :: proc() {
	g := tls.g

	last_frame: sdl3.Time
	assert(sdl3.GetCurrentTime(&last_frame))
	for !g.should_quit {
		when ENABLE_PROFILING {
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
				imgui_impl_sdl3.ProcessEvent(&e)

				#partial switch e.type {
				case .QUIT:
					g.should_quit = true
				case .WINDOW_RESIZED:
					g.window_width = e.window.data1
					g.window_height = e.window.data2

				}
			}
			imgui_impl_sdlgpu3.NewFrame()
			imgui_impl_sdl3.NewFrame()
			im.NewFrame()

			build_gui(g)

			im.Render()
			draw_data := im.GetDrawData()
			command_buffer := sdl3.AcquireGPUCommandBuffer(g.gpu_device)
			swapchain_texture: ^sdl3.GPUTexture
			swapchain_ok := sdl3.WaitAndAcquireGPUSwapchainTexture(
				command_buffer,
				g.window,
				&swapchain_texture,
				nil,
				nil,
			)
			assert(swapchain_ok)

			if swapchain_texture != nil {
				// This is mandatory: call PrepareDrawData() to upload the vertex/index buffer!
				imgui_impl_sdlgpu3.PrepareDrawData(draw_data, command_buffer)

				color_target_infos := sdl3.GPUColorTargetInfo {
					texture     = swapchain_texture,
					clear_color = {0, 0, 0, 1},
					load_op     = .CLEAR,
					store_op    = .STORE,
				}
				render_pass := sdl3.BeginGPURenderPass(command_buffer, &color_target_infos, 1, nil)
				imgui_impl_sdlgpu3.RenderDrawData(draw_data, command_buffer, render_pass)

				sdl3.EndGPURenderPass(render_pass)
			}

			when ENABLE_DOCKING {
				im.UpdatePlatformWindows()
				im.RenderPlatformWindowsDefault()
			}

			assert(sdl3.SubmitGPUCommandBuffer(command_buffer))

		}


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


// Automatic profiling of every procedure:

@(instrumentation_enter)
spall_enter :: proc "contextless" (
	proc_address, call_site_return_address: rawptr,
	loc: runtime.Source_Code_Location,
) {

	when ENABLE_PROFILING {
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
	when ENABLE_PROFILING {
		g := tls.g
		if g != nil {
			spall._buffer_end(&g.spall_ctx, tls.spall_buffer)
		}
	}
}

@(thread_local)
tls: TLS

G :: struct {
	should_quit:   bool,
	spall_ctx:     spall.Context,
	window_width:  i32,
	window_height: i32,


	//UI
	im_io:         ^im.IO,

	//Persistent State
	contacts:      [dynamic]Contact,
	transfers:     [dynamic]Transfer,


	//platform specific
	window:        ^sdl3.Window,
	atlas_texture: ^sdl3.Texture,
	gpu_device:    ^sdl3.GPUDevice,
}
Contact :: struct {
	name:       string,
	public_key: string, //TODO: make real public key
}
Transfer :: struct {
	file_name:                    string,
	file_size:                    int,
	counter_party:                Contact,
	status:                       TransferStatus,
	file_slices_to_be_transfered: [dynamic]FileSlice,
	rate:                         f64,
}
FileSlice :: struct {
	offset: int,
	len:    int,
}
TransferStatus :: enum {
	NotStarted,
	//...
	Transferring,
}
TLS :: struct {
	g:            ^G,
	lane_id:      int,
	lane_count:   int,
	barrier:      ^sync.Barrier,
	spall_buffer: ^spall.Buffer,
}
