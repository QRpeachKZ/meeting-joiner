import Foundation
import MeetingJoinerCore
import Security

final class ExchangeSecurityDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let settings: ExchangeSettings

    init(settings: ExchangeSettings) { self.settings = settings }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if settings.tlsMode != .insecureWarning {
            guard let source = response.url, let target = request.url,
                  source.scheme?.lowercased() == "https", target.scheme?.lowercased() == "https",
                  source.host?.lowercased() == target.host?.lowercased(),
                  (source.port ?? 443) == (target.port ?? 443) else {
                completionHandler(nil)
                return
            }
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let trust = space.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            guard settings.tlsMode == .customCA,
                  let label = settings.customCALabel,
                  let certificate = KeychainStore.certificate(label: label) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let setStatus = SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
            let combineStatus = SecTrustSetAnchorCertificatesOnly(trust, false)
            var error: CFError?
            let trusted = setStatus == errSecSuccess && combineStatus == errSecSuccess && SecTrustEvaluateWithError(trust, &error)
            completionHandler(trusted ? .useCredential : .cancelAuthenticationChallenge,
                              trusted ? URLCredential(trust: trust) : nil)
            return
        }
        if space.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           let label = settings.clientIdentityLabel,
           let identity = KeychainStore.identity(label: label) {
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
