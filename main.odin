#+feature dynamic-literals
package main

import im "3rdparty/imgui"
import "3rdparty/imgui/imgui_impl_sdl3"
import "3rdparty/imgui/imgui_impl_sdlgpu3"
import "base:runtime"
import "core:bytes"
import "core:crypto"
import "core:crypto/aead"
import "core:crypto/chacha20poly1305"
import "core:crypto/hkdf"
import "core:crypto/sha2"
import "core:crypto/x25519"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
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
	context.logger = log.create_console_logger()

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
		lane_ctx := LaneContext{i, lane_count, &bootstrap_barrier}

		when ENABLE_PROFILING {
			buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
			// defer delete(buffer_backing)
			temp_tls.spall_buffer = new(spall.Buffer)
			temp_tls.spall_buffer^ = spall.buffer_create(buffer_backing, u32(i))

			spall_buffers[i - 1] = temp_tls.spall_buffer
		}
		threads[i - 1] = thread.create_and_start_with_poly_data3(
			g,
			lane_ctx,
			spall_buffers[i - 1],
			multithread_entry_point,
			init_context = context,
		)
	}


	when ENABLE_PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		temp_tls.spall_buffer = new(spall.Buffer)
		temp_tls.spall_buffer^ = spall.buffer_create(buffer_backing, 0)
	}

	lane_ctx := LaneContext{0, lane_count, &bootstrap_barrier}
	multithread_entry_point(g, lane_ctx, spall_buffers[0])

	thread.join_multiple(..threads)
	when ENABLE_PROFILING {
		for buffer in spall_buffers {
			spall.buffer_destroy(&g.spall_ctx, buffer)
		}
		spall.buffer_destroy(&g.spall_ctx, temp_tls.spall_buffer)


		spall.context_destroy(&g.spall_ctx)
	}
}

multithread_entry_point :: proc(g: ^G, lane_ctx: LaneContext, spall_buffer: ^spall.Buffer) {

	tls.lane_ctx = lane_ctx
	tls.spall_ctx = spall_buffer
	tls.g = g

	if true {
		run_tests()
		return
	}

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
		g.my_name = "Dan"
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
		im.Text("%s", cstr(g.my_name))
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
	//TODO enable once we have persistence
	if false && len(g.my_name) == 0 {
		if im.BeginPopupModal("Enter your name") {
			@(static) inputted_name: [MAX_NAME_SIZE]u8
			im.Text("Please enter the name you want your contacts to know you by:")
			submit := im.InputText(
				"Name",
				cstring(raw_data(&inputted_name)),
				len(inputted_name),
				{.EnterReturnsTrue},
			)
			if submit || im.Button("OK") {
				//TODO check and save name

			}
			im.EndPopup()

		}
		im.OpenPopup("Enter your name")

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
lane_range :: proc(count: $T) -> (start: T, end: T) {
	lane_count: T = auto_cast lane_count()
	lane_id: T = auto_cast lane_id()

	values_per_thread := count / lane_count
	leftover_values_count := count % lane_count
	thread_has_leftover := lane_id < leftover_values_count
	leftovers_before_this_thread_idx := lane_id if thread_has_leftover else leftover_values_count

	start = values_per_thread * lane_id + leftovers_before_this_thread_idx
	end = start + values_per_thread + (1 if thread_has_leftover else 0)
	return
}

@(deferred_none = lane_pop_ctx)
lane_push_ctx :: proc(new_lane_count: int, new_lane_id: int, barrier: ^sync.Barrier) -> bool {
	// fmt.printf("lane_push_ctx: %v\n", lane_id())
	append(&tls.lane_contexts, tls.lane_ctx)

	tls.lane_count = new_lane_count
	tls.lane_id = new_lane_id
	tls.barrier = barrier

	return new_lane_id < new_lane_count
}
lane_pop_ctx :: proc() {
	// fmt.printf("lane_pop_ctx: %v\n", lane_id())
	tls.lane_ctx = pop(&tls.lane_contexts)
}

//TODO push lane context

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
	should_quit:       bool,
	spall_ctx:         spall.Context,
	window_width:      i32,
	window_height:     i32,


	//UI
	im_io:             ^im.IO,

	//Persistent State
	contacts:          [dynamic]Contact,
	transfers:         [dynamic]Transfer,
	my_name:           string,
	master_secret_key: SecretKey,


	//platform specific
	window:            ^sdl3.Window,
	atlas_texture:     ^sdl3.Texture,
	gpu_device:        ^sdl3.GPUDevice,
}

//File Transfer related
MAX_NAME_SIZE :: 128
MAX_FILE_NAME_SIZE :: 512

PublicKey :: distinct [x25519.POINT_SIZE]byte
SecretKey :: distinct [x25519.SCALAR_SIZE]byte
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

//Send Files Protocol (SFP) stuff
SFP_VERSION :: i32(0)
SFPPacketHeader :: struct #packed {
	version:          i32,
	op:               SFPOp,
	session_id:       PublicKey,
	encryption_tag:   [chacha20poly1305.TAG_SIZE]byte,
	encryption_nonce: [chacha20poly1305.XIV_SIZE]byte,
}

SFPAddress :: struct #packed {
	label:      [16]byte, //This is used by the recipient to derive the secret key from their master secret key
	public_key: PublicKey,
}

create_sfp_address :: proc(
	master_secret_key: SecretKey,
) -> (
	address: SFPAddress,
	secret_key: SecretKey,
) {
	master_secret_key := master_secret_key

	crypto.rand_bytes(address.label[:])

	sha_ctx: sha2.Context_256
	sha2.init_256(&sha_ctx)
	sha2.update(&sha_ctx, master_secret_key[:])
	sha2.update(&sha_ctx, address.label[:])
	sha2.final(&sha_ctx, secret_key[:])

	x25519.scalarmult_basepoint(address.public_key[:], secret_key[:])

	return
}
derive_secret_key_from_sfp_address :: proc(
	address: SFPAddress,
	master_secret_key: SecretKey,
) -> SecretKey {
	result: SecretKey

	master_secret_key := master_secret_key
	address := address

	sha_ctx: sha2.Context_256
	sha2.init_256(&sha_ctx)
	sha2.update(&sha_ctx, master_secret_key[:])
	sha2.update(&sha_ctx, address.label[:])
	sha2.final(&sha_ctx, result[:])

	return result
}

SFPFileSendRequest :: struct #packed {
	using header:      SFPPacketHeader,
	target_address:    SFPAddress,
	encrypted_payload: [size_of(SFPFileSendRequestPayload)]byte,
}
SFPFileSendRequestPayload :: struct #packed {
	reply_ip_address: nbio.IP4_Address,
	reply_port:       u16,
	file_size:        i64,
	file_name:        [dynamic; MAX_FILE_NAME_SIZE]byte,
	requester_name:   [dynamic; MAX_NAME_SIZE]byte,
}


#assert(
	size_of(SFPFileSendRequest) == 4 + 4 + 32 + 32 + 16 + 16 + 24 + 4 + 2 + 8 + 8 + 512 + 8 + 128,
)

init_sfp_file_send_request :: proc(
	ephemeral_secret_key: SecretKey,
	target_address: SFPAddress,
	file_size: i64,
	file_name: string,
	requester_name: string,
	reply_ip_address: nbio.IP4_Address,
	reply_port: u16,
	out_packet: ^SFPFileSendRequest,
) {
	out_packet.version = SFP_VERSION
	out_packet.op = .FileSendRequest

	//set up payload to be encrypted
	payload: SFPFileSendRequestPayload
	{
		payload.file_size = file_size
		resize(&payload.file_name, len(file_name))
		copy(payload.file_name[:], file_name[:])
		resize(&payload.requester_name, len(requester_name))
		copy(payload.requester_name[:], requester_name[:])
		payload.reply_ip_address = reply_ip_address
		payload.reply_port = reply_port
	}


	//calculate the encryption key
	encryption_key: SecretKey
	{
		ephemeral_secret_key := ephemeral_secret_key
		x25519.scalarmult_basepoint(out_packet.session_id[:], ephemeral_secret_key[:])

		out_packet.target_address = target_address

		x25519.scalarmult(
			encryption_key[:],
			ephemeral_secret_key[:],
			out_packet.target_address.public_key[:],
		)

		sha_ctx: sha2.Context_256
		sha2.init_256(&sha_ctx)
		sha2.update(&sha_ctx, encryption_key[:])
		sha2.final(&sha_ctx, encryption_key[:])
	}

	crypto.rand_bytes(out_packet.encryption_nonce[:])

	payload_bytes := mem.byte_slice(&payload, size_of(payload))

	aead.seal_oneshot(
		.XCHACHA20POLY1305,
		payload_bytes,
		out_packet.encryption_tag[:],
		encryption_key[:],
		out_packet.encryption_nonce[:],
		nil,
		payload_bytes,
	)
	copy(out_packet.encrypted_payload[:], payload_bytes[:])
}
parse_sfp_file_send_request :: proc(
	target_secret_key: SecretKey,
	out_payload: ^SFPFileSendRequestPayload,
	in_packet: ^SFPFileSendRequest,
) -> bool {
	//calculate the encryption key
	encryption_key: SecretKey
	{
		target_secret_key := target_secret_key

		x25519.scalarmult(encryption_key[:], target_secret_key[:], in_packet.session_id[:])

		sha_ctx: sha2.Context_256
		sha2.init_256(&sha_ctx)
		sha2.update(&sha_ctx, encryption_key[:])
		sha2.final(&sha_ctx, encryption_key[:])
	}

	garbage := [24]byte{}
	decrypted := aead.open_oneshot(
		.XCHACHA20POLY1305,
		in_packet.encrypted_payload[:],
		encryption_key[:],
		in_packet.encryption_nonce[:],
		nil,
		in_packet.encrypted_payload[:],
		in_packet.encryption_tag[:],
	)
	if !decrypted {
		return false
	}

	decrypted_payload := transmute(^SFPFileSendRequestPayload)&in_packet.encrypted_payload
	out_payload^ = decrypted_payload^

	return true

}


SFP_MAX_DATA_CHUNK_SIZE :: 16 * 1024

SFPFileDataPacket :: struct #packed {
	using header: SFPPacketHeader,
	payload:      [size_of(SFPFileDataPayload)]byte,
}
#assert(size_of(SFPFileDataPacket) == 4 + 4 + 32 + 24 + 16 + 8 + 8 + 16 * 1024)

SFPFileDataPayload :: struct #packed {
	file_offset:     i64,
	file_data_chunk: [dynamic; SFP_MAX_DATA_CHUNK_SIZE]byte,
}

init_sfp_file_data_packet :: proc(offset: i64, data: []byte, out_packet: ^SFPFileDataPacket) {
}

SFPOp :: enum (i32) {
	None = 0,
	FileSendRequest,
	AcceptFileSendRequest,
	FileData,
	ResendFileData,
}

//Application specific
TLS :: struct {
	g:              ^G,
	spall_ctx:      ^spall.Buffer,
	using lane_ctx: LaneContext,
	lane_contexts:  [dynamic; 64]LaneContext,
}
LaneContext :: struct {
	lane_id:    int,
	lane_count: int,
	barrier:    ^sync.Barrier,
}
