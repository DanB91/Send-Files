package main

import "core:crypto"
import "core:crypto/sha2"
import "core:crypto/x25519"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:sync"
import sfp "send_files_protocol"
run_tests :: proc() {
	g := tls.g

	test_constructing_parsing_file_send_request_packet()
	test_sending_file_send_request()
	// test_send_ping_pong()
	// test_file_transfer()
	lane_sync()
	if is_main_thread() {
		fmt.printfln("All tests passed!")
	}


}

test_constructing_parsing_file_send_request_packet :: proc() {
	if is_main_thread() {
		sender_ephemeral_secret_key: sfp.SecretKey
		crypto.rand_bytes(sender_ephemeral_secret_key[:])

		target_master_secret_key: sfp.SecretKey
		crypto.rand_bytes(target_master_secret_key[:])

		target_address, target_secret_key := sfp.create_sfp_address(target_master_secret_key)

		x25519.scalarmult_basepoint(target_address.public_key[:], target_secret_key[:])

		packet: sfp.FileSendRequest

		FILE_NAME :: "hello.mp4"
		FILE_SIZE :: 1234
		REQUESTER_NAME :: "Dan"
		IP_ADDR :: nbio.IP4_Address{127, 0, 0, 1}
		PORT :: 12345

		sfp.init_sfp_file_send_request(
			sender_ephemeral_secret_key,
			target_address,
			FILE_SIZE,
			FILE_NAME,
			REQUESTER_NAME,
			IP_ADDR,
			PORT,
			&packet,
		)
		payload: sfp.FileSendRequestPayload
		ok := sfp.parse_sfp_file_send_request(target_master_secret_key, &payload, &packet)
		ensure(ok)
		ensure(string(payload.file_name[:]) == FILE_NAME)
		ensure(payload.file_size == FILE_SIZE)
		ensure(string(payload.requester_name[:]) == REQUESTER_NAME)
		ensure(payload.reply_ip_address == IP_ADDR)
		ensure(payload.reply_port == PORT)

	}

}
test_sending_file_send_request :: proc() {
	FILE_NAME :: "hello.mp4"
	FILE_SIZE :: 1234
	REQUESTER_NAME :: "Dan"
	IP_ADDR :: nbio.IP4_Address{127, 0, 0, 1}
	PORT :: 12345
	DISCOVER_NODE_PORT :: 54321
	RECEIVER_CLIENT_PORT :: 65432

	@(static) receiver_master_sk: sfp.SecretKey
	@(static) receiver_address: sfp.Address
	@(static) receiver_address_sk: sfp.SecretKey
	if is_main_thread() {
		_, receiver_master_sk = sfp.create_key_pair()
		receiver_address, receiver_address_sk = sfp.create_sfp_address(receiver_master_sk)
	}
	lane_sync()


	if is_main_thread() {
		nbio.acquire_thread_event_loop()
		defer nbio.release_thread_event_loop()
		ephemeral_pk, ephemperal_sk := sfp.create_key_pair()
		file_send_request_packet: sfp.FileSendRequest
		sfp.init_sfp_file_send_request(
			ephemperal_sk,
			receiver_address,
			FILE_SIZE,
			FILE_NAME,
			REQUESTER_NAME,
			IP_ADDR,
			PORT,
			&file_send_request_packet,
		)
		socket, socket_err := nbio.create_udp_socket(.IP4)
		ensure(socket_err == .None)
		defer {
			nbio.close(socket)
			nbio.run()
		}
		nbio.send(
			socket,
			{mem.byte_slice(&file_send_request_packet, size_of(file_send_request_packet))},
			proc(op: ^nbio.Operation) {
				err := op.recv.err
				if err != nil {
					log.errorf("Sending file send request failed %v", err)
					ensure(false)
				}
			},
			{nbio.IP4_Loopback, RECEIVER_CLIENT_PORT},
		)
		err := nbio.run()
		ensure(err == .None)


	} else if is_io_thread() {
		nbio.acquire_thread_event_loop()
		defer nbio.release_thread_event_loop()

		socket, socket_err := nbio.create_udp_socket(.IP4)
		ensure(socket_err == .None)
		bind_err := nbio.bind(socket, {nbio.IP4_Loopback, RECEIVER_CLIENT_PORT})
		ensure(bind_err == .None)
		defer {
			nbio.close(socket)
			nbio.run()
		}

		file_send_request: sfp.FileSendRequest
		nbio.recv(
			socket,
			{mem.byte_slice(&file_send_request, size_of(file_send_request))},
			proc(op: ^nbio.Operation) {
				err := op.recv.err
				if err == nil {
					incoming_packet := cast(^sfp.FileSendRequest)raw_data(op.recv.bufs[0])
					payload: sfp.FileSendRequestPayload

					success := sfp.parse_sfp_file_send_request(
						receiver_master_sk,
						&payload,
						incoming_packet,
					)
					ensure(success)
					ensure(string(payload.file_name[:]) == FILE_NAME)
					ensure(payload.file_size == FILE_SIZE)
					ensure(string(payload.requester_name[:]) == REQUESTER_NAME)
					ensure(payload.reply_ip_address == IP_ADDR)
					ensure(payload.reply_port == PORT)

				} else {
					log.errorf("Receiving file send request failed %v", err)
					ensure(false)
				}
			},
			true,
		)
		err := nbio.run()
		ensure(err == .None)

	}
	lane_sync()
}


//TODO this is wrong, since there is no synchronization between sender adn receiver.
//     so the sender will almost send some packets into the ether
// test_file_transfer :: proc() {
// 	TestingG :: struct {
// 		read_file_handle:  nbio.Handle,
// 		write_file_handle: nbio.Handle,
// 		file_size:         i64,
// 		send_socket:       nbio.UDP_Socket,
// 		receive_socket:    nbio.UDP_Socket,
// 	}
// 	@(static) g: TestingG

// 	ensure(lane_count() % 2 == 0)

// 	new_lane_count := lane_count() / 2
// 	@(static) sender_barrier: sync.Barrier
// 	@(static) receiver_barrier: sync.Barrier
// 	if is_main_thread() {
// 		sync.barrier_init(&sender_barrier, new_lane_count)
// 		sync.barrier_init(&receiver_barrier, new_lane_count)

// 		open_err: nbio.FS_Error
// 		g.read_file_handle, open_err = nbio.open_sync("test_files/Sonic2HD.zip")
// 		ensure(open_err == .None)
// 		nbio.stat_poly(g.read_file_handle, &g, proc(op: ^nbio.Operation, g: ^TestingG) {
// 			g.file_size = op.stat.size
// 		})
// 		log.info("File size ", g.file_size)
// 		nbio.run()
// 	}
// 	defer {
// 		if is_main_thread() {
// 			nbio.close(g.read_file_handle)
// 		}
// 	}
// 	lane_sync()

// 	RECEVER_ENDPOINT :: nbio.Endpoint{nbio.IP4_Loopback, 54321}

// 	if lane_id() < new_lane_count {
// 		//sender

// 		lane_push_ctx(new_lane_count, lane_id(), &sender_barrier)
// 		if is_main_thread() {
// 			socket_err: nbio.Create_Socket_Error
// 			g.send_socket, socket_err = nbio.create_udp_socket(.IP4)
// 			ensure(socket_err == .None)
// 		}
// 		defer if is_main_thread() {
// 			nbio.close(g.send_socket)
// 		}

// 		nbio.acquire_thread_event_loop()
// 		defer nbio.release_thread_event_loop()

// 		lane_sync()

// 		//TODO send request for file

// 		//send file
// 		send_ctx: SendContext
// 		send_ctx.start, send_ctx.end = lane_range(int(g.file_size))
// 		SendContext :: struct {
// 			start:  int,
// 			end:    int,
// 			offset: int,
// 			buffer: [sfp._FILE_DATA_CHUNK_SIZE]byte,
// 		}

// 		send_ctx.offset = send_ctx.start


// 		file_read_callback :: proc(op: ^nbio.Operation, g: ^TestingG, send_ctx: ^SendContext) {
// 			file_packet: sfp.FileDataPacket
// 			init_sfp_file_data_packet(auto_cast op.read.offset, op.read.buf, &file_packet)
// 			logf("Sending %v bytes: %v/%v", len(op.read.buf), op.read.offset, g.file_size)
// 			nbio.send_poly2(
// 				g.send_socket,
// 				{file_packet[:]},
// 				g,
// 				send_ctx,
// 				send_file_callback,
// 				RECEVER_ENDPOINT,
// 			)
// 		}
// 		send_file_callback :: proc(op: ^nbio.Operation, g: ^TestingG, send_ctx: ^SendContext) {
// 			send_ctx.offset += op.send.sent
// 			to_send := min(send_ctx.end - send_ctx.offset, sfp._FILE_DATA_CHUNK_SIZE)
// 			if to_send > 0 {
// 				nbio.read_poly2(
// 					g.read_file_handle,
// 					send_ctx.offset,
// 					op.read.buf[:],
// 					g,
// 					send_ctx,
// 					file_read_callback,
// 				)
// 			}
// 		}
// 		nbio.read_poly2(
// 			g.read_file_handle,
// 			send_ctx.offset,
// 			send_ctx.buffer[:],
// 			&g,
// 			&send_ctx,
// 			file_read_callback,
// 		)

// 		err := nbio.run()
// 		ensure(err == .None)

// 	} else {
// 		lane_push_ctx(new_lane_count, lane_id() - new_lane_count, &receiver_barrier)

// 		//receiver

// 		if is_main_thread() {
// 			open_err: nbio.FS_Error
// 			g.write_file_handle, open_err = nbio.open_sync(
// 				"test_files/Sonic2HD_copy.zip",
// 				mode = {.Create, .Trunc},
// 			)
// 			socket_err: nbio.Create_Socket_Error
// 			g.receive_socket, socket_err = nbio.create_udp_socket(.IP4)
// 			ensure(socket_err == .None)
// 			nbio.bind(g.receive_socket, RECEVER_ENDPOINT)
// 		}
// 		defer {
// 			if is_main_thread() {
// 				nbio.close(g.write_file_handle)
// 				nbio.close(g.receive_socket)
// 			}
// 		}
// 	}


// }
logf :: proc($fmt: string, args: ..any) {
	log.infof("From %v: " + fmt, lane_id(), args)
}
test_send_ping_pong :: proc() {
	lane_count := 2
	@(static) new_barrier: sync.Barrier
	if is_main_thread() {
		sync.barrier_init(&new_barrier, lane_count)
	}
	lane_sync()
	if lane_push_ctx(lane_count, lane_id(), &new_barrier) {
		old_lane_state := tls.lane_ctx
		defer tls.lane_ctx = old_lane_state


		tls.lane_count = lane_count
		tls.barrier = &new_barrier

		err := nbio.acquire_thread_event_loop()
		defer nbio.release_thread_event_loop()

		ensure(err == .None)

		this_port := 12345 if is_main_thread() else 54321
		this_endpoint := nbio.Endpoint{nbio.IP4_Loopback, this_port}

		other_port := 54321 if is_main_thread() else 12345
		other_endpoint := nbio.Endpoint{nbio.IP4_Loopback, other_port}

		socket, socket_err := nbio.create_udp_socket(.IP4)
		ensure(socket_err == .None)

		bind_err := nbio.bind(socket, this_endpoint)
		ensure(bind_err == .None)


		if is_main_thread() {
			nbio.send(socket, {transmute([]u8)string("hello")}, proc(op: ^nbio.Operation) {
					log.infof("sent!")
				}, other_endpoint)
		} else {
			buf: [6]u8
			nbio.recv(socket, {buf[:]}, proc(op: ^nbio.Operation) {
					for buf in op.recv.bufs {
						log.infof("Received '%v'", string(buf))
					}

				}, true)
		}
		nbio.run()

	}
	lane_sync()
}
