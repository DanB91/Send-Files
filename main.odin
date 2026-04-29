#+feature dynamic-literals
#+vet explicit-allocators

package main

import im "3rdparty/imgui"
import "3rdparty/imgui/imgui_impl_sdl3"
import "3rdparty/imgui/imgui_impl_sdlgpu3"
import igfd "3rdparty/imgui_file_dialog"
import "base:runtime"
import "core:bytes"
import "core:c"
import "core:container/queue"
import "core:crypto"
import "core:crypto/aead"
import "core:crypto/chacha20poly1305"
import "core:crypto/hkdf"
import "core:crypto/sha2"
import "core:crypto/x25519"
import "core:encoding/base64"
import "core:fmt"
import "core:io"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:prof/spall"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:thread"
import "core:time"
import sfp "send_files_protocol"
import "vendor:sdl3"

INITIAL_WINDOW_WIDTH :: 800
INITIAL_WINDOW_HEIGHT :: 800
FONT_MULTIPLIER :: 1

ENABLE_PROFILING :: false
ENABLE_DOCKING :: false
ENABLE_PACKET_STATS :: true

SERVER_ENDPOINT :: nbio.Endpoint{nbio.IP4_Address{107, 23, 192, 242}, 12345}

main :: proc() {
	context.logger = log.create_console_logger(allocator = context.allocator)
	context.logger.lowest_level = .Info

	lane_count := os.get_processor_core_count()
	g := new(G, context.allocator)
	bootstrap_barrier: sync.Barrier
	sync.barrier_init(&bootstrap_barrier, lane_count)

	temp_tls: TLS
	temp_tls.g = g
	temp_tls.lane_count = lane_count
	temp_tls.barrier = &bootstrap_barrier

	when ENABLE_PROFILING {
		g.spall_ctx = spall.context_create("trace_test.spall")
	}


	threads := make([]^thread.Thread, lane_count - 1, context.allocator)
	spall_buffers := make([]^spall.Buffer, lane_count - 1, context.allocator)
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

	run_tests()

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
		g.igfd_ctx = igfd.Create()


		//init placeholder values.  TODO: remove after we implement persistance
		g.my_name = "Dan"
		_, g.master_secret_key = sfp.create_key_pair()

		io_to_main, err := chan.create(chan.Chan(MainThreadCommand), 1024, context.allocator)
		ensure(err == nil)
		g.io_to_main = io_to_main

		// append(
		// 	&g.transfers,
		// 	Transfer {
		// 		"Handmade Hero Episode 1.mp4",
		// 		1234567890,
		// 		Contact{"Bob", "654321"},
		// 		.NotStarted,
		// 		nil,
		// 		0,
		// 	},
		// )
		// append(
		// 	&g.transfers,
		// 	Transfer {
		// 		"Handmade Hero Episode 2.mp4",
		// 		1234567890,
		// 		Contact{"Bob", "654321"},
		// 		.NotStarted,
		// 		nil,
		// 		0,
		// 	},
		// )
	} else if is_io_thread() {

		err := nbio.acquire_thread_event_loop()
		ensure(err == nil)
		g.io_event_loop = nbio.current_thread_event_loop()
		socket, socket_err := nbio.create_udp_socket(.IP4, g.io_event_loop)
		ensure(socket_err == nil)
		g.socket = socket
	}
	lane_sync()


	if is_main_thread() {
		run_ui()
		nbio.wake_up(g.io_event_loop)
	} else if is_io_thread() {
		//IO thread

		//Ping Server Timer
		{
			ping_server :: proc(op: ^nbio.Operation, g: ^G) {
				@(static) ping_packet := sfp.Ping{{sfp.VERSION, sfp.PING_MAGIC}}
				nbio.send_poly(
					g.socket,
					{mem.ptr_to_bytes(&ping_packet)},
					g,
					proc(op: ^nbio.Operation, g: ^G) {
						if op.send.err == nil {
							when ENABLE_PACKET_STATS {
								_ = chan.try_send(
									g.io_to_main,
									NewPacketStat{.PingAndPong, .Outgoing},
								)
							}
						} else {
							log.warnf("Error sending ping to server: %v", op.send.err)
						}
						log.debugf("Sent ping")
					},
					SERVER_ENDPOINT,
					l = g.io_event_loop,
				)

				nbio.timeout_poly(5 * time.Second, g, ping_server)
			}
			nbio.timeout_poly(0, g, ping_server)
		}


		//Listen for Pong packets
		pong_packet: sfp.Pong
		{
			recv_pong :: proc(op: ^nbio.Operation, g: ^G, pong_packet: ^sfp.Pong) {
				if op.recv.err == nil {
					if pong_packet.version == sfp.VERSION && pong_packet.magic == sfp.PONG_MAGIC {
						ip := net.Address(pong_packet.external_ip)
						endpoint := net.Endpoint{ip, auto_cast pong_packet.external_port}

						_ = chan.try_send(g.io_to_main, NewIPAddress{endpoint})
						when ENABLE_PACKET_STATS {
							_ = chan.try_send(g.io_to_main, NewPacketStat{.PingAndPong, .Incoming})
						}
					} else {
						log.infof("Received bad pong packet: %v", op.send.err)
						when ENABLE_PACKET_STATS {
							_ = chan.try_send(g.io_to_main, NewPacketStat{.PingAndPong, .Invalid})
						}
					}
				} else {
					log.warnf("Error receiving pong packet: %v", op.send.err)
				}
				nbio.recv_poly2(g.socket, op.recv.bufs, g, pong_packet, recv_pong)
			}
			nbio.recv_poly2(g.socket, {mem.ptr_to_bytes(&pong_packet)}, g, &pong_packet, recv_pong)
		}
		//Listen for FileSendRequest packets
		file_send_request_packet: sfp.FileSendRequest
		{
			recv_file_send_request :: proc(
				op: ^nbio.Operation,
				g: ^G,
				packet: ^sfp.FileSendRequest,
			) {
				if op.recv.err == nil {
					if packet.version == sfp.VERSION {
						payload: sfp.FileSendRequestPayload
						if sfp.parse_sfp_file_send_request(g.master_secret_key, &payload, packet) {
							_ = chan.try_send(g.io_to_main, NewFileSendRequest{payload})
							when ENABLE_PACKET_STATS {
								_ = chan.try_send(
									g.io_to_main,
									NewPacketStat{.FileSendRequest, .Incoming},
								)
							}
						} else {
							when ENABLE_PACKET_STATS {
								_ = chan.try_send(
									g.io_to_main,
									NewPacketStat{.FileSendRequest, .Invalid},
								)
							}

						}
					}
				} else {
					log.warnf("Error receiving FileSendRequest packet: %v", op.send.err)
				}
			}
		}


		for !g.should_quit {
			err := nbio.tick()
			if err != nil {
				fmt.printfln("IO Error: %v", err)
			}
		}
	}
	lane_sync()
}
build_gui :: proc(g: ^G) {
	ContactSerialized :: struct #packed {
		address:    sfp.Address,
		name_len:   u32,
		name_store: [sfp.MAX_NAME_SIZE]byte,
		crc32:      u32,
	}
	ui_contact_text :: proc(contact: Contact) {
		contact := contact
		address_string := base64.encode(contact.address[:], allocator = context.temp_allocator)
		im.PushStyleColor(.Text, 0xFF_00_FF_00)
		im.Text("%s", cstr(string(contact.name[:])))
		im.PopStyleColor()
		im.SameLine()
		im.Text("<%s>", cstr(address_string))

	}

	cstr :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s, context.temp_allocator)
	}
	im.SetNextWindowPos({0, 0})
	im.SetNextWindowSize(g.im_io.DisplaySize)
	im.Begin("Main", nil, {.NoCollapse, .NoResize, .NoTitleBar})
	// im.SetWindowFontScale(2)

	//UI Section connection status
	{

		im.BeginChild("Connection Status", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("Connection Status")
		if g.external_ip_address.port != 0 {
			text := fmt.ctprintf(
				"%v",
				net.endpoint_to_string(g.external_ip_address, context.temp_allocator),
			)
			im.Text("Connected as %s", text)
		} else {
			im.Text("Not Connected")
		}

		im.EndChild()
	}
	//UI Section Packet Stats
	when ENABLE_PACKET_STATS {
		im.BeginChild("Packet Stats", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("Packet Stats")
		if im.BeginTable("Packet Stats", 4) {
			im.TableSetupColumn("Type")
			im.TableSetupColumn("# Incoming Valid Packets")
			im.TableSetupColumn("# Incoming Invalid Packets")
			im.TableSetupColumn("# Outgoing Packets")
			im.TableHeadersRow()
			for stat, i in g.packet_stats {
				im.PushIDInt(auto_cast i)

				packet_type := fmt.ctprintf("%v", cast(PacketType)i)

				im.TableNextColumn()
				im.Text("%s", packet_type)
				im.TableNextColumn()
				im.Text("%d", stat.incoming)
				im.TableNextColumn()
				im.Text("%d", stat.outgoing)
				im.TableNextColumn()
				im.Text("%d", stat.invalid)

				im.PopID()
			}
			im.EndTable()
		}
		im.EndChild()

	}

	//UI Section: Contact info
	{
		im.BeginChild("Your Contact Info", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("Your Contact Info")
		im.Text("%s", cstr(g.my_name))
		im.SameLine()
		if im.Button("Copy") {
			address := sfp.create_sfp_address(g.master_secret_key)
			contact_info: ContactSerialized
			contact_info.address = address
			contact_info.name_len = auto_cast len(g.my_name)
			copy(contact_info.name_store[:], g.my_name[:])

			crc: u32
			init_crc32(&crc)
			digest_crc32(contact_info.address[:], &crc)
			digest_crc32(mem.ptr_to_bytes(&contact_info.name_len), &crc)
			digest_crc32(contact_info.name_store[:], &crc)
			crc = final_crc32(&crc)
			contact_info.crc32 = crc

			to_copy := base64.encode(
				mem.byte_slice(&contact_info, size_of(contact_info)),
				allocator = context.temp_allocator,
			)


			im.SetClipboardText(cstr(to_copy))
		}
		im.SameLine()
		if im.Button("Edit Name") {
		}
		im.EndChild()
	}
	//UI Section: Contacts
	{
		im.BeginChild("Contacts", child_flags = {.Borders, .AutoResizeY})
		im.SeparatorText("Contacts")
		if im.BeginTable("Contacts", 4) {

			for &contact, i in g.contacts {
				im.TableNextColumn()
				im.PushIDInt(auto_cast i)
				im.TableNextColumn()
				ui_contact_text(contact)
				im.SameLine()
				if g.external_ip_address.port != 0 && im.Button("Send File") {
					config := igfd.FileDialog_Config_Get()
					//TODO fill out config
					config.flags = {.Modal, .ReadOnlyFileNameField, .DisableCreateDirectoryButton}
					config.user_datas = &contact
					igfd.OpenDialog(
						g.igfd_ctx,
						"Choose File To Send",
						"Choose File To Send",
						".*",
						config,
					)
					// panel := Foundation.OpenPanel_openPanel()
					// panel->setCanChooseDirectories(false)
					// if panel->runModal() == .OK {
					// 	url := panel->URL()
					// 	path := string(url->fileSystemRepresentation())
					// 	file_name := filepath.base(path)
					// 	file_info, err := os.stat(path, context.temp_allocator)
					// 	if err == nil {
					// 		packet: sfp.FileSendRequest
					// 		pk, sk := sfp.create_key_pair()
					// 		//TODO start sending file send request packet

					// 		// init_sfp_file_send_request(
					// 		// 	sk,
					// 		// 	contact.address,
					// 		// 	file_info.size,
					// 		// 	file_name,
					// 		// 	g.my_name,
					// 		// )
					// 	} else {
					// 		//TODO error message
					// 		log.errorf("Failed to stat file %v: %v ", path, err)
					// 	}

					// }

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
		if im.Button("Paste New Contact", {button_width, 0}) {
			clipboard_text := string(im.GetClipboardText())
			decoded := base64.decode(clipboard_text, allocator = context.temp_allocator)
			if len(decoded) == size_of(ContactSerialized) {
				contact_info := cast(^ContactSerialized)raw_data(decoded)
				crc: u32
				init_crc32(&crc)
				digest_crc32(contact_info.address[:], &crc)
				digest_crc32(mem.ptr_to_bytes(&contact_info.name_len), &crc)
				digest_crc32(contact_info.name_store[:], &crc)
				crc = final_crc32(&crc)
				if crc == contact_info.crc32 {
					if contact_info.name_len < len(contact_info.name_store) {
						//TODO check if this is yourself
						//TODO check if you already have this contact
						contact: Contact
						contact.address = contact_info.address
						append(
							&contact.name,
							string(contact_info.name_store[:contact_info.name_len]),
						)
						append(&g.contacts, contact)

					} else {
						im.OpenPopup("Invalid Contact Info")
					}
				} else {
					im.OpenPopup("Invalid Contact Info")
				}
			} else {
				im.OpenPopup("Invalid Contact Info")
			}
		}
		if im.BeginPopupModal("Invalid Contact Info") {
			im.Text("Invalid Contact Info")
			if im.Button("Damn") {
				im.CloseCurrentPopup()
			}
			im.EndPopup()
		}
		im.EndChild()

	}
	//UI Section: File transfers
	{
		human_readable_file_size :: proc(size: i64) -> cstring {
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
			for &tr, i in g.transfers {
				im.PushIDInt(auto_cast i)

				im.TableNextColumn()
				im.Text("%s", cstr(tr.file_name))

				im.TableNextColumn()
				ui_contact_text(tr.counter_party)

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
	//UI Section: Enter your name Dialog
	if false && len(g.my_name) == 0 {
		if im.BeginPopupModal("Enter your name") {
			@(static) inputted_name: [sfp.MAX_NAME_SIZE]u8
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

	////UI Section: "Choose File To Send" dialog
	if igfd.DisplayDialog(
		g.igfd_ctx,
		"Choose File To Send",
		{.NoCollapse},
		{INITIAL_WINDOW_WIDTH / 1.25, INITIAL_WINDOW_HEIGHT / 1.5},
		{max(f32), max(f32)},
	) {
		if igfd.IsOk(g.igfd_ctx) {
			path := string(igfd.GetFilePathName(g.igfd_ctx, .KeepInputFile))
			file_name := filepath.base(path)
			file_info, err := os.stat(path, context.temp_allocator)
			if err == nil {
				session_id, sk := sfp.create_key_pair()
				contact := cast(^Contact)igfd.GetUserDatas(g.igfd_ctx)

				append(&g.transfers, Transfer{})

				transfer := &g.transfers[len(g.transfers) - 1]
				{
					transfer_arena: mem.Arena
					mem.arena_init(&transfer_arena, make([]byte, 512 * 1024, context.allocator))
					transfer_allocator := mem.arena_allocator(&transfer_arena)

					file_slices_to_be_transfered := make([dynamic]FileSlice, transfer_allocator)
					append(&file_slices_to_be_transfered, FileSlice{0, file_info.size})


					transfer^ = Transfer {
						allocator                    = transfer_allocator,
						file_name                    = strings.clone(
							file_name,
							transfer_allocator,
						),
						file_size                    = file_info.size,
						counter_party                = contact^,
						status                       = .Requested,
						file_slices_to_be_transfered = file_slices_to_be_transfered,
						rate                         = 0,
					}
				}

				packet := new(sfp.FileSendRequest, transfer.allocator)
				sfp.init_sfp_file_send_request(
					sk,
					session_id,
					contact.address,
					file_info.size,
					file_name,
					g.my_name,
					g.external_ip_address.address.(net.IP4_Address),
					auto_cast g.external_ip_address.port,
					packet,
				)
				repeat_file_send_request_until_accepted :: proc(
					op: ^nbio.Operation,
					packet: ^sfp.FileSendRequest,
					transfer: ^Transfer,
					g: ^G,
				) {

					nbio.send_poly(
						g.socket,
						{mem.ptr_to_bytes(packet)},
						g,
						proc(op: ^nbio.Operation, g: ^G) {
							if op.send.err == nil {
								when ENABLE_PACKET_STATS {
									_ = chan.try_send(
										g.io_to_main,
										NewPacketStat{.FileSendRequest, .Outgoing},
									)
								}
							} else {
								log.warnf("Error sending file send request: %v", op.send.err)
							}
						},
						SERVER_ENDPOINT,
					)
					if transfer.status == .Requested {
						nbio.timeout_poly3(
							5 * time.Second,
							packet,
							transfer,
							g,
							repeat_file_send_request_until_accepted,
							g.io_event_loop,
						)

					}
				}
				nbio.timeout_poly3(
					0,
					packet,
					transfer,
					g,
					repeat_file_send_request_until_accepted,
					g.io_event_loop,
				)
			} else {
				//TODO error message
				log.errorf("Failed to stat file %v: %v ", path, err)
			}

		}
		igfd.CloseDialog(g.igfd_ctx)
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
		if received, ok := chan.try_recv(g.io_to_main); ok {
			switch command in received {
			case NewIPAddress:
				g.external_ip_address = command.endpoint
			case NewPacketStat:
				stat := &g.packet_stats[command.type]
				switch command.stat {
				case .Incoming:
					stat.incoming += 1
				case .Outgoing:
					stat.outgoing += 1
				case .Invalid:
					stat.invalid += 1
				}
			case NewFileSendRequest:
			//TODO add contact addres to NewFileSendRequest
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

is_main_thread :: proc() -> bool {
	return lane_id() == 0
}
is_io_thread :: proc() -> bool {
	return lane_id() == 1
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

@(thread_local)
tls: TLS

G :: struct {
	should_quit:         bool,
	spall_ctx:           spall.Context,
	window_width:        i32,
	window_height:       i32,


	//UI
	im_io:               ^im.IO,
	igfd_ctx:            ^igfd.ImGuiFileDialog,

	//UI Transient State
	external_ip_address: net.Endpoint,
	packet_stats:        [PacketType.Count]PacketStat,

	//Persistent State
	contacts:            [dynamic; 4096]Contact,
	transfers:           [dynamic; 4096]Transfer,
	my_name:             string,
	master_secret_key:   sfp.SecretKey,

	//IO
	io_event_loop:       ^nbio.Event_Loop,
	socket:              nbio.UDP_Socket,

	//Inter-thread communication
	io_to_main:          chan.Chan(MainThreadCommand),


	//platform specific
	window:              ^sdl3.Window,
	atlas_texture:       ^sdl3.Texture,
	gpu_device:          ^sdl3.GPUDevice,
}

PacketType :: enum {
	PingAndPong = 0,
	FileSendRequest,
	FileSendRequestAccept,
	Count,
}

PacketStat :: struct {
	incoming, outgoing, invalid: int,
}

MainThreadCommand :: union {
	NewIPAddress,
	NewPacketStat,
	NewFileSendRequest,
}
NewIPAddress :: struct {
	endpoint: net.Endpoint,
}
NewPacketStat :: struct {
	type: PacketType,
	stat: enum {
		Incoming,
		Outgoing,
		Invalid,
	},
}
NewFileSendRequest :: struct {
	request: sfp.FileSendRequestPayload,
	// sender_address: sfp.Address,
	// session_id:     sfp.PublicKey,
}

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


//File Transfer related

Contact :: struct {
	name:    [dynamic; sfp.MAX_NAME_SIZE]byte,
	address: sfp.Address,
}
Transfer :: struct {
	allocator:                    mem.Allocator,
	file_name:                    string,
	file_size:                    i64,
	counter_party:                Contact,
	status:                       TransferStatus,
	file_slices_to_be_transfered: [dynamic]FileSlice,
	rate:                         f64,
	session_id:                   sfp.PublicKey,
}
FileSlice :: struct {
	offset: i64,
	len:    i64,
}
TransferStatus :: enum {
	NotStarted,
	Requested,
	//...
	Transferring,
}

//Send Files Protocol (SFP) stuff

//Application specific

//crc32
init_crc32 :: proc(crc: ^u32) {
	crc^ = 0xffffffff
}
digest_crc32 :: proc(data: []byte, crc: ^u32) {
	for b in data {
		crc^ = crc32_table[byte(crc^) ~ b] ~ (crc^ >> 8)
	}
}
final_crc32 :: proc(crc: ^u32) -> u32 {
	return ~crc^
}

crc32_table := [256]u32 {
	0,
	0x77073096,
	0xEE0E612C,
	0x990951BA,
	0x076DC419,
	0x706AF48F,
	0xE963A535,
	0x9E6495A3,
	0x0EDB8832,
	0x79DCB8A4,
	0xE0D5E91E,
	0x97D2D988,
	0x09B64C2B,
	0x7EB17CBD,
	0xE7B82D07,
	0x90BF1D91,
	0x1DB71064,
	0x6AB020F2,
	0xF3B97148,
	0x84BE41DE,
	0x1ADAD47D,
	0x6DDDE4EB,
	0xF4D4B551,
	0x83D385C7,
	0x136C9856,
	0x646BA8C0,
	0xFD62F97A,
	0x8A65C9EC,
	0x14015C4F,
	0x63066CD9,
	0xFA0F3D63,
	0x8D080DF5,
	0x3B6E20C8,
	0x4C69105E,
	0xD56041E4,
	0xA2677172,
	0x3C03E4D1,
	0x4B04D447,
	0xD20D85FD,
	0xA50AB56B,
	0x35B5A8FA,
	0x42B2986C,
	0xDBBBC9D6,
	0xACBCF940,
	0x32D86CE3,
	0x45DF5C75,
	0xDCD60DCF,
	0xABD13D59,
	0x26D930AC,
	0x51DE003A,
	0xC8D75180,
	0xBFD06116,
	0x21B4F4B5,
	0x56B3C423,
	0xCFBA9599,
	0xB8BDA50F,
	0x2802B89E,
	0x5F058808,
	0xC60CD9B2,
	0xB10BE924,
	0x2F6F7C87,
	0x58684C11,
	0xC1611DAB,
	0xB6662D3D,
	0x76DC4190,
	0x01DB7106,
	0x98D220BC,
	0xEFD5102A,
	0x71B18589,
	0x06B6B51F,
	0x9FBFE4A5,
	0xE8B8D433,
	0x7807C9A2,
	0x0F00F934,
	0x9609A88E,
	0xE10E9818,
	0x7F6A0DBB,
	0x086D3D2D,
	0x91646C97,
	0xE6635C01,
	0x6B6B51F4,
	0x1C6C6162,
	0x856530D8,
	0xF262004E,
	0x6C0695ED,
	0x1B01A57B,
	0x8208F4C1,
	0xF50FC457,
	0x65B0D9C6,
	0x12B7E950,
	0x8BBEB8EA,
	0xFCB9887C,
	0x62DD1DDF,
	0x15DA2D49,
	0x8CD37CF3,
	0xFBD44C65,
	0x4DB26158,
	0x3AB551CE,
	0xA3BC0074,
	0xD4BB30E2,
	0x4ADFA541,
	0x3DD895D7,
	0xA4D1C46D,
	0xD3D6F4FB,
	0x4369E96A,
	0x346ED9FC,
	0xAD678846,
	0xDA60B8D0,
	0x44042D73,
	0x33031DE5,
	0xAA0A4C5F,
	0xDD0D7CC9,
	0x5005713C,
	0x270241AA,
	0xBE0B1010,
	0xC90C2086,
	0x5768B525,
	0x206F85B3,
	0xB966D409,
	0xCE61E49F,
	0x5EDEF90E,
	0x29D9C998,
	0xB0D09822,
	0xC7D7A8B4,
	0x59B33D17,
	0x2EB40D81,
	0xB7BD5C3B,
	0xC0BA6CAD,
	0xEDB88320,
	0x9ABFB3B6,
	0x03B6E20C,
	0x74B1D29A,
	0xEAD54739,
	0x9DD277AF,
	0x04DB2615,
	0x73DC1683,
	0xE3630B12,
	0x94643B84,
	0x0D6D6A3E,
	0x7A6A5AA8,
	0xE40ECF0B,
	0x9309FF9D,
	0x0A00AE27,
	0x7D079EB1,
	0xF00F9344,
	0x8708A3D2,
	0x1E01F268,
	0x6906C2FE,
	0xF762575D,
	0x806567CB,
	0x196C3671,
	0x6E6B06E7,
	0xFED41B76,
	0x89D32BE0,
	0x10DA7A5A,
	0x67DD4ACC,
	0xF9B9DF6F,
	0x8EBEEFF9,
	0x17B7BE43,
	0x60B08ED5,
	0xD6D6A3E8,
	0xA1D1937E,
	0x38D8C2C4,
	0x4FDFF252,
	0xD1BB67F1,
	0xA6BC5767,
	0x3FB506DD,
	0x48B2364B,
	0xD80D2BDA,
	0xAF0A1B4C,
	0x36034AF6,
	0x41047A60,
	0xDF60EFC3,
	0xA867DF55,
	0x316E8EEF,
	0x4669BE79,
	0xCB61B38C,
	0xBC66831A,
	0x256FD2A0,
	0x5268E236,
	0xCC0C7795,
	0xBB0B4703,
	0x220216B9,
	0x5505262F,
	0xC5BA3BBE,
	0xB2BD0B28,
	0x2BB45A92,
	0x5CB36A04,
	0xC2D7FFA7,
	0xB5D0CF31,
	0x2CD99E8B,
	0x5BDEAE1D,
	0x9B64C2B0,
	0xEC63F226,
	0x756AA39C,
	0x026D930A,
	0x9C0906A9,
	0xEB0E363F,
	0x72076785,
	0x05005713,
	0x95BF4A82,
	0xE2B87A14,
	0x7BB12BAE,
	0x0CB61B38,
	0x92D28E9B,
	0xE5D5BE0D,
	0x7CDCEFB7,
	0x0BDBDF21,
	0x86D3D2D4,
	0xF1D4E242,
	0x68DDB3F8,
	0x1FDA836E,
	0x81BE16CD,
	0xF6B9265B,
	0x6FB077E1,
	0x18B74777,
	0x88085AE6,
	0xFF0F6A70,
	0x66063BCA,
	0x11010B5C,
	0x8F659EFF,
	0xF862AE69,
	0x616BFFD3,
	0x166CCF45,
	0xA00AE278,
	0xD70DD2EE,
	0x4E048354,
	0x3903B3C2,
	0xA7672661,
	0xD06016F7,
	0x4969474D,
	0x3E6E77DB,
	0xAED16A4A,
	0xD9D65ADC,
	0x40DF0B66,
	0x37D83BF0,
	0xA9BCAE53,
	0xDEBB9EC5,
	0x47B2CF7F,
	0x30B5FFE9,
	0xBDBDF21C,
	0xCABAC28A,
	0x53B39330,
	0x24B4A3A6,
	0xBAD03605,
	0xCDD70693,
	0x54DE5729,
	0x23D967BF,
	0xB3667A2E,
	0xC4614AB8,
	0x5D681B02,
	0x2A6F2B94,
	0xB40BBE37,
	0xC30C8EA1,
	0x5A05DF1B,
	0x2D02EF8D,
}


//thread-safe queue
// ThreadSafeQueue :: struct($T: typeid) {
// 	q:     queue.Queue(T),
// 	mutex: sync.Mutex,
// }
// init_queue :: proc(q: ^ThreadSafeQueue) {
// 	queue.init(q.q)
// }
// push :: proc(q: ^$Q/ThreadSafeQueue($T), item: T) {
// 	sync.guard(&q.mutex)
// 	queue.push(q.q, item)
// }
