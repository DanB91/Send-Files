package main
import sfp "../send_files_protocol"
import "core:container/lru"
import "core:container/pool"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:prof/spall"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
ENABLE_PROFILING :: false
PORT :: 12345
main :: proc() {
	context.logger = log.create_console_logger(.Warning, allocator = context.allocator)
	context.logger.options |= {.Thread_Id}

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
	if is_main_thread() {
		args := os.args
		if len(args) != 2 {
			fmt.printfln("Specify a listen address!")
			os.exit(1)
		}
		ok: bool
		g.listen_address, ok = net.parse_ip4_address(args[1])
		if !ok {
			fmt.printfln("Specify a valid listen address!")
			os.exit(1)
		}

		log.infof(
			"Will listen on %v.%v.%v.%v:%v",
			g.listen_address[0],
			g.listen_address[1],
			g.listen_address[2],
			g.listen_address[3],
			PORT,
		)
		{
			listen_socket, err := net.create_socket(.IP4, .UDP)
			ensure(err == nil)
			g.socket = listen_socket.(net.UDP_Socket)
		}

		{
			err := net.bind(g.socket, {g.listen_address, PORT})
			ensure(err == nil)
		}

		io_thread_count := lane_count() - 1
		g.channel_futexes = make([]sync.Futex, io_thread_count)
		g.ping_channels = make([]chan.Chan(net.Endpoint), io_thread_count)
		for &c in g.ping_channels {
			err: mem.Allocator_Error
			c, err = chan.create_buffered(type_of(c), 1024, context.allocator)
		}
		g.file_send_request_packet_channels = make(
			[]chan.Chan(sfp.FileSendRequest),
			io_thread_count,
		)
		for &c in g.file_send_request_packet_channels {
			err: mem.Allocator_Error
			c, err = chan.create_buffered(type_of(c), 1024, context.allocator)
		}

	}
	lane_sync()
	if is_main_thread() {
		//Listen thread
		lane_push_ctx(1, 0, nil)
		ReceiveBuffer :: struct #raw_union {
			send_request:        sfp.FileSendRequest,
			ping:                sfp.Ping,
			send_request_accept: sfp.FileSendRequestAccept,
		}
		buf: ReceiveBuffer

		for {
			bytes_read, source, err := net.recv_udp(g.socket, mem.ptr_to_bytes(&buf))
			if err == nil {
				switch bytes_read {
				case size_of(buf.ping):
					if buf.ping.magic == sfp.PING_MAGIC {
						switch addr in source.address {
						case nbio.IP4_Address:
							id := lane_id_for_ip_source(source, g)
							c := g.ping_channels[id]
							ok := chan.try_send(c, source)
							if ok {
								sync.futex_broadcast(&g.channel_futexes[id])
							} else {
								log.warnf("IO thread %v is slow!", id)
							}
						case nbio.IP6_Address:
						}
					} else {
						log.infof("Received bad ping packet with contents: %X", buf.ping.magic)
					}
				case size_of(buf.send_request):
					for c, id in g.file_send_request_packet_channels {
						ok := chan.try_send(c, buf.send_request)
						if ok {
							sync.futex_broadcast(&g.channel_futexes[id])
						} else {
							log.warnf("IO thread %v is slow!", id)
						}
					}
				case size_of(buf.send_request_accept):
					id := lane_id_for_ip_source(source, g)
				//TODO
				case:
					log.infof("Received unexpected number of bytes: %v", bytes_read)
				}
			} else {
				log.infof("Error in socket: %v", err)
			}
		}


	} else {
		//Worker threads
		lane_push_ctx(lane_count() - 1, lane_id() - 1, nil)

		known_clients: lru.Cache(net.Endpoint, struct {})
		lru.init(&known_clients, 1024)
		file_send_request_packet_channel := g.file_send_request_packet_channels[lane_id()]
		ping_channel := g.ping_channels[lane_id()]
		futex := &g.channel_futexes[lane_id()]

		nbio.acquire_thread_event_loop()
		defer nbio.release_thread_event_loop()
		nbio.associate_socket(g.socket)

		for {
			sync.futex_wait(futex, auto_cast futex^)
			futex^ += 1
			keep_going := true


			for keep_going {
				keep_going = false
				if ping_source, ok := chan.try_recv(ping_channel); ok {
					lru.set(&known_clients, ping_source, struct{}{})
					pong_packet := sfp.Pong {
						{sfp.VERSION, sfp.PONG_MAGIC},
						ping_source.address.(net.IP4_Address),
						auto_cast ping_source.port,
					}
					log.infof("Sent pong to %v", ping_source)
					nbio.send(
						g.socket,
						{mem.ptr_to_bytes(&pong_packet)},
						proc(op: ^nbio.Operation) {
							if op.send.err == nil {
								log.infof("Sent pong")
							} else {
								log.errorf("Error sending pong packet: %v", op.send.err)

							}
						},
						ping_source,
					)
					nbio.run()
					keep_going = true
				}
				if packet, ok := chan.try_recv(file_send_request_packet_channel); ok {
					for endpoint in known_clients.entries {
						nbio.send(
							g.socket,
							{mem.ptr_to_bytes(&packet)},
							proc(op: ^nbio.Operation) {
								if op.send.err != nil {
									log.errorf(
										"Error sending file request packet: %v",
										op.send.err,
									)
								}
							},
							endpoint,
						)
					}
					nbio.run()
					keep_going = true
				}
			}

		}
	}


}

lane_id_for_ip_source :: proc(source: net.Endpoint, g: ^G) -> int {
	source := source
	index := hash.murmur32(mem.ptr_to_bytes(&source)) % auto_cast lane_count()
	return auto_cast index
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

@(thread_local)
tls: TLS


G :: struct {
	listen_address:                    net.IP4_Address,
	socket:                            net.UDP_Socket,
	ping_channels:                     []chan.Chan(net.Endpoint),
	file_send_request_packet_channels: []chan.Chan(sfp.FileSendRequest),
	//TODO
	// rendezvous_channels:               []chan.Chan(sfp.Rendezvous),
	channel_futexes:                   []sync.Futex,
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
