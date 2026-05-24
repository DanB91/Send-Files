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
	sender_address:      Address,
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
SessionID :: [16]byte

create_key_pair :: proc() -> (public_key: PublicKey, secret_key: SecretKey) {
	crypto.rand_bytes(secret_key[:])
	x25519.scalarmult_basepoint(public_key[:], secret_key[:])
	return
}

create_session_id :: proc() -> (session_id: SessionID) {
	crypto.rand_bytes(session_id[:])
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
	session_id:           SessionID,
}


#assert(
	size_of(FileSendRequest) ==
	4 +
		4 +
		4 +
		4 +
		32 +
		16 +
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
decrypt_encryption_packet :: proc(
	header: EncryptionHeader,
	secret_key: SecretKey,
	in_out_payload: []byte,
) -> bool {
	encryption_key: SecretKey
	{

		secret_key := secret_key
		sender_address := header.sender_address
		//Uhhh I haven't thought this out as much as I should have (as usual)
		//The issue is that the file send request is encrypted with the ephmeral private key that is associated with the session id
		//But, don't we want the packets to be encrypted with the sender's public key?
		//How do we incorporate both the sender's public key and the ephmeral session id?
		x25519.scalarmult(encryption_key[:], secret_key[:], sender_address[:])

		sha_ctx: sha2.Context_256
		sha2.init_256(&sha_ctx)
		sha2.update(&sha_ctx, encryption_key[:])
		sha2.final(&sha_ctx, encryption_key[:])
	}
	return false
}

init_sfp_file_send_request :: proc(
	secret_key: SecretKey,
	session_id: SessionID,
	target_address: Address,
	file_size: i64,
	file_name: string,
	requester_contact: ^Contact,
	reply_ip_address: nbio.IP4_Address,
	reply_port: u16,
	out_packet: ^FileSendRequest,
) {
	out_packet.version = VERSION
	out_packet.type = .Encrypted
	out_packet.size = size_of(FileSendRequest)

	//set up payload to be encrypted
	payload: FileSendRequestPayload
	{
		payload.op = .FileSendRequest
		payload.file_size = file_size
		append(&payload.file_name, file_name)
		append(&payload.requester_name, ..requester_contact.name[:])
		payload.reply_ip_address = reply_ip_address
		payload.reply_port = reply_port
		payload.session_id = session_id
	}


	//calculate the encryption key
	encryption_key: SecretKey
	{
		secret_key := secret_key
		out_packet.sender_address = requester_contact.address

		out_packet.target_address = target_address

		x25519.scalarmult(encryption_key[:], secret_key[:], out_packet.target_address[:])

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

		x25519.scalarmult(encryption_key[:], target_secret_key[:], in_packet.sender_address[:])

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
	using header: PacketPayloadHeader,
	session_id:   SessionID,
}
init_sfp_file_send_request_accept :: proc(
	secret_key: SecretKey,
	receiver_address: Address,
	session_id: SessionID,
	my_contact_info: ^Contact,
	out_packet: ^FileSendRequestAccept,
) {
	secret_key := secret_key
	out_packet.version = VERSION

	//set up payload to be encrypted
	payload: FileSendRequestAcceptPayload
	{
		payload.op = .AcceptFileSendRequest
		payload.session_id = session_id
	}


	//calculate the encryption key
	encryption_key: SecretKey
	{
		out_packet.sender_address = my_contact_info.address
		x25519.scalarmult(encryption_key[:], secret_key[:], my_contact_info.address[:])

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

Contact :: struct {
	name:    [dynamic; MAX_NAME_SIZE]byte,
	address: Address,
}
