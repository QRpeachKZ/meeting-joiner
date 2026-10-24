import AppKit
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class GoogleAuthorizationFlow {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Error>?
    private var expectedState = ""
    private var codeVerifier = ""

    private struct Callback {
        let code: String
        let verifier: String
        let redirectURI: String
    }

    func authorize(clientID: String) async throws -> (code: String, verifier: String, redirectURI: String) {
        let verifier = Self.randomURLSafeString()
        let stateToken = Self.randomURLSafeString()
        codeVerifier = verifier
        expectedState = stateToken
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let result: Callback = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch listenerState {
                    case .ready:
                        guard let port = listener.port else {
                            self.finish(.failure(AuthorizationError.listenerUnavailable))
                            return
                        }
                        let redirectURI = "http://127.0.0.1:\(port.rawValue)/callback"
                        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                        components.queryItems = [
                            URLQueryItem(name: "client_id", value: clientID),
                            URLQueryItem(name: "redirect_uri", value: redirectURI),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.readonly"),
                            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
                            URLQueryItem(name: "code_challenge_method", value: "S256"),
                            URLQueryItem(name: "state", value: stateToken),
                            URLQueryItem(name: "access_type", value: "offline"),
                            URLQueryItem(name: "prompt", value: "consent")
                        ]
                        self.acceptConnections(listener)
                        guard let url = components.url, NSWorkspace.shared.open(url) else {
                            self.finish(.failure(AuthorizationError.cannotOpenBrowser))
                            return
                        }
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: break
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        return (result.code, result.verifier, result.redirectURI)
    }

    private func acceptConnections(_ listener: NWListener) {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor [weak self] in
                self?.receiveRequest(on: connection, accumulated: Data())
            }
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                self?.processRequestData(data, on: connection, accumulated: accumulated, isComplete: isComplete)
            }
        }
    }

    private func processRequestData(_ data: Data, on connection: NWConnection, accumulated: Data, isComplete: Bool) {
        let received = accumulated + data
        guard let request = String(data: received, encoding: .utf8) else {
            respond("Authorization was not completed. You can close this tab.", on: connection)
            return
        }
        guard request.contains("\r\n\r\n") else {
            if isComplete || received.count >= 16_384 {
                respond("Authorization was not completed. You can close this tab.", on: connection)
            } else {
                receiveRequest(on: connection, accumulated: received)
            }
            return
        }
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return }
        let pieces = firstLine.split(separator: " ")
        guard pieces.count >= 2 else { return }
        let target = "http://127.0.0.1" + String(pieces[1])
        guard let components = URLComponents(string: target), components.path == "/callback",
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == expectedState else {
            respond("Authorization was not completed. You can close this tab.", on: connection)
            return
        }
        if components.queryItems?.first(where: { $0.name == "error" })?.value != nil {
            respond("Google authorization was cancelled. You can close this tab.", on: connection)
            finish(.failure(AuthorizationError.authorizationDenied))
            return
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let port = listener?.port else {
            respond("Authorization was not completed. You can close this tab.", on: connection)
            return
        }
        let callback = Callback(code: code, verifier: codeVerifier,
                                redirectURI: "http://127.0.0.1:\(port.rawValue)/callback")
        respond("Google Calendar connected. You can close this tab and return to Meeting Joiner.", on: connection)
        finish(.success(callback))
    }

    private func respond(_ message: String, on connection: NWConnection) {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>Meeting Joiner</title><p>\(message)</p>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private enum AuthorizationError: Error, LocalizedError {
        case listenerUnavailable
        case cannotOpenBrowser
        case authorizationDenied
        var errorDescription: String? {
            switch self {
            case .listenerUnavailable: return "Could not start the local OAuth callback listener."
            case .cannotOpenBrowser: return "Could not open the system browser for Google sign-in."
            case .authorizationDenied: return "Google authorization was cancelled or denied."
            }
        }
    }
}
