package sfp
import "core:crypto"
import "core:crypto/aead"
import "core:crypto/chacha20poly1305"
import "core:crypto/sha2"
import "core:crypto/x25519"
import "core:mem"
import "core:nbio"
VERSION :: i32(0)
MAX_NAME_SIZE :: 64
MAX_FILE_NAME_SIZE :: 512

PacketHeader :: struct #packed {
	size:    i32,
	version: i32,
	type:    enum (i32) {
		Ping,
		Pong,
		Encrypted,
	},
}


Ping :: struct #packed {
	using header: PacketHeader,
}
create_ping_packet :: proc() -> Ping {
	result := Ping{{size_of(Ping), VERSION, .Ping}}
	return result
}
Pong :: struct #packed {
	using header:  PacketHeader,
	external_ip:   nbio.IP4_Address,
	external_port: u16,
}
create_pong_packet :: proc(external_ip: nbio.IP4_Address, external_port: u16) -> Pong {
	result := Pong{{size_of(Pong), VERSION, .Pong}, external_ip, external_port}
	return result
}

//unencrypted header containing only necessary information needed for decryption
EncryptionHeader :: struct #packed {
	using packet_header: PacketHeader,
	session_id:          SessionID,
	encryption_tag:      [chacha20poly1305.TAG_SIZE]byte,
	encryption_nonce:    [chacha20poly1305.XIV_SIZE]byte,
}
//All encrypted payloads must start with this header
PacketPayloadHeader :: struct #packed {
	op: Op,
}
PublicKey :: distinct [x25519.POINT_SIZE]byte
SecretKey :: distinct [x25519.SCALAR_SIZE]byte

Address :: distinct PublicKey
SessionID :: distinct PublicKey

create_key_pair :: proc() -> (public_key: PublicKey, secret_key: SecretKey) {
	crypto.rand_bytes(secret_key[:])
	x25519.scalarmult_basepoint(public_key[:], secret_key[:])
	return
}

create_session_id :: proc() -> (session_id: SessionID, secret_key: SecretKey) {
	pk, sk := create_key_pair()
	session_id = auto_cast pk
	secret_key = sk
	return
}

create_address :: proc() -> (address: Address, secret_key: SecretKey) {
	pk, sk := create_key_pair()
	address = auto_cast pk
	secret_key = sk
	return
}


validate_sfp_address_is_mine :: proc(address: Address, secret_key: SecretKey) -> bool {
	secret_key := secret_key
	calculated_address: Address
	x25519.scalarmult_basepoint(calculated_address[:], secret_key[:])
	if address != calculated_address {
		return false
	}
	return true
}

FileSendRequest :: struct #packed {
	using encryption_header: EncryptionHeader,
	target_address:          Address,
	encrypted_payload:       [size_of(FileSendRequestPayload)]byte,
}
FileSendRequestPayload :: struct #packed {
	using payload_header: PacketPayloadHeader,
	reply_ip_address:     nbio.IP4_Address,
	reply_port:           u16,
	file_size:            i64,
	file_name:            [dynamic; MAX_FILE_NAME_SIZE]byte,
	requester_name:       [dynamic; MAX_NAME_SIZE]byte,
	requester_address:    Address,
}


#assert(
	size_of(FileSendRequest) ==
	4 +
		4 +
		4 +
		4 +
		32 +
		32 +
		16 +
		24 +
		4 +
		2 +
		8 +
		8 +
		MAX_FILE_NAME_SIZE +
		8 +
		MAX_NAME_SIZE +
		32,
)

init_sfp_file_send_request :: proc(
	ephemeral_secret_key: SecretKey,
	session_id: SessionID,
	target_address: Address,
	file_size: i64,
	file_name: string,
	requester_address: Address,
	requester_name: string,
	reply_ip_address: nbio.IP4_Address,
	reply_port: u16,
	out_packet: ^FileSendRequest,
) {
	out_packet.version = VERSION
	out_packet.packet_header.size = size_of(FileSendRequest)

	//set up payload to be encrypted
	payload: FileSendRequestPayload
	{
		payload.op = .FileSendRequest
		payload.file_size = file_size
		resize(&payload.file_name, len(file_name))
		copy(payload.file_name[:], file_name[:])
		resize(&payload.requester_name, len(requester_name))
		copy(payload.requester_name[:], requester_name[:])
		payload.reply_ip_address = reply_ip_address
		payload.reply_port = reply_port
		payload.requester_address = requester_address
	}


	//calculate the encryption key
	encryption_key: SecretKey
	{
		ephemeral_secret_key := ephemeral_secret_key
		out_packet.session_id = session_id

		out_packet.target_address = target_address

		x25519.scalarmult(encryption_key[:], ephemeral_secret_key[:], out_packet.target_address[:])

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
	out_payload: ^FileSendRequestPayload,
	in_packet: ^FileSendRequest,
) -> bool {
	target_secret_key := target_secret_key

	//calculate the encryption key
	encryption_key: SecretKey
	{
		valid := validate_sfp_address_is_mine(in_packet.target_address, target_secret_key)
		if !valid {
			return false
		}

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

	decrypted_payload := transmute(^FileSendRequestPayload)&in_packet.encrypted_payload
	out_payload^ = decrypted_payload^

	return true

}

FileSendRequestAccept :: struct #packed {
	using header:      EncryptionHeader,
	encrypted_payload: [size_of(FileSendRequestAcceptPayload)]byte,
}
FileSendRequestAcceptPayload :: struct #packed {
	using header:     PacketPayloadHeader,
	receiver_address: Address, //used for validation purposes
}
init_sfp_file_send_request_accept :: proc(
	secret_key: SecretKey,
	receiver_address: Address,
	session_id: SessionID,
	out_packet: ^FileSendRequestAccept,
) {
	secret_key := secret_key
	out_packet.version = VERSION

	//set up payload to be encrypted
	payload: FileSendRequestAcceptPayload
	{
		payload.op = .AcceptFileSendRequest
		payload.receiver_address = receiver_address
	}


	//calculate the encryption key
	encryption_key: SecretKey
	{
		x25519.scalarmult_basepoint(out_packet.session_id[:], secret_key[:])


		session_id := session_id
		x25519.scalarmult(encryption_key[:], secret_key[:], session_id[:])

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


_MAX_DATA_CHUNK_SIZE :: 16 * 1024

FileDataPacket :: struct #packed {
	using header: EncryptionHeader,
	payload:      [size_of(FileDataPayload)]byte,
}
// #assert(size_of(FileDataPacket) == 4 + 4 + 32 + 24 + 16 + 8 + 8 + 16 * 1024)

FileDataPayload :: struct #packed {
	file_offset:     i64,
	file_data_chunk: [dynamic; _MAX_DATA_CHUNK_SIZE]byte,
}

init_sfp_file_data_packet :: proc(offset: i64, data: []byte, out_packet: ^FileDataPacket) {
}

Op :: enum (i32) {
	None = 0,
	FileSendRequest,
	AcceptFileSendRequest,
	FileData,
	ResendFileData,
}
