// First Row's addition to SMBClient (see MediaEngine/README.md): signing in to a Mac's file
// sharing with Kerberos.
//
// A Mac keeps no NTLM form of an account's password unless "Windows File Sharing" is turned
// on for that account, so the name and password this library sends (NTLM) are refused by it,
// right as they may be. What a Mac does take is Kerberos, from its own key server, with the
// Kerberos messages carried inside the sign-in itself (IAKERB), which is how one Mac signs in
// to another. The system does all of it (the GSS framework, on a Mac, an iPhone and an iPad;
// the Apple TV has no such framework): this file hands it the name and the password, and
// passes its tokens to and from the server.

#if canImport(GSS)
import Foundation
import GSS

/// One sign-in with Kerberos through the system.
final class KerberosSignIn {
  struct Failure: LocalizedError {
    let what: String
    var errorDescription: String? { what }
  }

  /// The mark, in what a server offers at the start, that it takes Kerberos this way
  /// (the IAKERB mechanism, 1.3.6.1.5.2.5, as it is written in the offer).
  private static let offer = Data([0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x02, 0x05])

  /// Whether a server's offer (the security buffer of its answer to Negotiate) has that mark.
  static func isOffered(in securityBuffer: Data) -> Bool {
    securityBuffer.range(of: offer) != nil
  }

  private var credential: gss_cred_id_t?
  private var context: gss_ctx_id_t?
  private var target: gss_name_t?
  private(set) var isComplete = false

  /// `username` is an account's name on the Mac, short or full; with no realm in it, it is
  /// looked for in the Mac's own (under the name every Mac's own realm answers to).
  init(username: String, password: String) throws {
    var minor: OM_uint32 = 0
    let principal = username.contains("@") ? username : username + "@WELLKNOWN:COM.APPLE.LKDC"
    guard let name = Self.name(principal, &__gss_c_nt_user_name_oid_desc) else {
      throw Failure(what: "The name can't be used to sign in.")
    }
    defer {
      var name: gss_name_t? = name
      gss_release_name(&minor, &name)
    }
    // (A credential of its own each time: several sign-ins may be going on at once.)
    let attributes: [CFString: Any] = [
      "kGSSICPassword" as CFString: password as CFString,
      "kGSSICCreateNewCredential" as CFString: kCFBooleanTrue as Any,
    ]
    var error: Unmanaged<CFError>?
    let major = gss_aapl_initial_cred(name, &__gss_iakerb_mechanism_oid_desc, attributes as CFDictionary, &credential, &error)
    guard major == 0, credential != nil else {
      let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
      throw Failure(what: reason ?? "The system couldn't prepare the sign-in.")
    }
    // The file sharing of the Mac itself, by the name its own key server knows it under
    // whatever the Mac is called: asked for by the Mac's name or address, it isn't found.
    guard let service = Self.name("cifs/localhost@WELLKNOWN:COM.APPLE.LKDC", &__gss_krb5_nt_principal_name_oid_desc) else {
      throw Failure(what: "The server's name can't be used to sign in.")
    }
    target = service
  }

  deinit {
    var minor: OM_uint32 = 0
    if context != nil { gss_delete_sec_context(&minor, &context, nil) }
    if target != nil { gss_release_name(&minor, &target) }
    // (Out of the system's store, not only out of this program.)
    if credential != nil { gss_destroy_cred(&minor, &credential) }
  }

  /// What to send the server next, given what it last sent (nothing, to begin with). Nil
  /// once there is nothing more to send.
  func next(after received: Data?) throws -> Data? {
    guard let target else { throw Failure(what: "The sign-in wasn't prepared.") }
    var minor: OM_uint32 = 0
    var output = gss_buffer_desc()
    let flags = OM_uint32(GSS_C_MUTUAL_FLAG | GSS_C_INTEG_FLAG | GSS_C_REPLAY_FLAG | GSS_C_SEQUENCE_FLAG)
    func step(_ input: gss_buffer_t?) -> OM_uint32 {
      gss_init_sec_context(
        &minor, credential, &context, target, &__gss_spnego_mechanism_oid_desc, flags, 0, nil,
        input, nil, &output, nil, nil
      )
    }
    let major: OM_uint32
    if let received, !received.isEmpty {
      var bytes = [UInt8](received)
      major = bytes.withUnsafeMutableBytes { raw in
        var input = gss_buffer_desc(length: raw.count, value: raw.baseAddress)
        return step(&input)
      }
    } else {
      major = step(nil)
    }
    defer { gss_release_buffer(&minor, &output) }
    // (GSS_S_COMPLETE is 0 and GSS_S_CONTINUE_NEEDED 1; anything with its upper half set failed.)
    guard major & 0xFFFF_0000 == 0 else {
      throw Failure(what: Self.words(for: minor) ?? "The sign-in was refused.")
    }
    isComplete = major == 0
    guard output.length > 0, let value = output.value else { return nil }
    return Data(bytes: value, count: output.length)
  }

  /// The key the session's messages are signed with, once the sign-in is complete.
  func sessionKey() throws -> Data {
    guard let context else { throw Failure(what: "The sign-in isn't complete.") }
    var minor: OM_uint32 = 0
    var keys: gss_buffer_set_t?
    // (The system fills the set in; it is declared as never empty, which it is until then.)
    let major = withUnsafeMutablePointer(to: &keys) { place in
      place.withMemoryRebound(to: gss_buffer_set_t.self, capacity: 1) {
        gss_inquire_sec_context_by_oid(&minor, context, &__gss_c_inq_sspi_session_key_oid_desc, $0)
      }
    }
    defer { if keys != nil { gss_release_buffer_set(&minor, &keys) } }
    guard major == 0, let keys, keys.pointee.count > 0, let first = keys.pointee.elements, let value = first.pointee.value, first.pointee.length > 0 else {
      throw Failure(what: "The sign-in gave no key to sign with.")
    }
    return Data(bytes: value, count: first.pointee.length)
  }

  private static func name(_ text: String, _ kind: UnsafeMutablePointer<gss_OID_desc>) -> gss_name_t? {
    var minor: OM_uint32 = 0
    var name: gss_name_t?
    var bytes = Array(text.utf8)
    let major = bytes.withUnsafeMutableBytes { raw -> OM_uint32 in
      var buffer = gss_buffer_desc(length: raw.count, value: raw.baseAddress)
      return gss_import_name(&minor, &buffer, kind, &name)
    }
    return major == 0 ? name : nil
  }

  /// The system's own words for what went wrong.
  private static func words(for minor: OM_uint32) -> String? {
    var ignored: OM_uint32 = 0
    var more: OM_uint32 = 0
    var text = gss_buffer_desc()
    let major = gss_display_status(&ignored, minor, GSS_C_MECH_CODE, &__gss_krb5_mechanism_oid_desc, &more, &text)
    defer { gss_release_buffer(&ignored, &text) }
    guard major == 0, let value = text.value, text.length > 0 else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: value, count: text.length), as: UTF8.self)
  }
}
#endif
