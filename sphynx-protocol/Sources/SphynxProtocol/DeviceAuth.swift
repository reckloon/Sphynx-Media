import Foundation

/// Device authorization grant (RFC 8628-style) — passwordless sign-in for TVs and
/// other limited-input clients. The device shows a short code + a QR; the user
/// approves it on a second device where they're already signed in (e.g. with a
/// **passkey**); the device polls and receives the same `TokenResponse` as any
/// other login.
///
/// Flow:
/// 1. Device → `POST /v1/auth/device/start` ⇒ `DeviceAuthResponse`. It renders a QR
///    of `verificationUriComplete` and shows `userCode` for manual entry.
/// 2. User opens the URL on their phone (already authenticated), confirms, and the
///    phone calls `POST /v1/auth/device/approve { userCode }` (bearer-authenticated).
/// 3. Device polls `POST /v1/auth/device/token { deviceCode }` every `interval`
///    seconds: `authorization_pending` until approved, then a `TokenResponse`.
///
/// Advertised via `capabilities.deviceAuth` in `GET /v1/info`.
public struct DeviceAuthResponse: Codable, Hashable, Sendable {
    /// Secret the device polls with on `/auth/device/token`. Opaque; never shown to
    /// the user (the QR/userCode are what the user sees).
    public var deviceCode: String
    /// Short, human-typable code shown on the device (e.g. `"WXYZ-1234"`), entered
    /// by the user on the verification page if they can't scan the QR.
    public var userCode: String
    /// Where the user goes to approve (e.g. `https://server/link`). The bare form,
    /// for "enter this code at …" instructions.
    public var verificationUri: String
    /// `verificationUri` with the code embedded (e.g. `…/link?code=WXYZ-1234`) — the
    /// string the device encodes into the QR so a scan needs no typing.
    public var verificationUriComplete: String
    /// Minimum seconds the device SHOULD wait between `/auth/device/token` polls.
    public var interval: Double
    /// Seconds until this request expires (the device must restart after).
    public var expiresIn: Double

    public init(
        deviceCode: String, userCode: String, verificationUri: String,
        verificationUriComplete: String, interval: Double, expiresIn: Double
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.verificationUriComplete = verificationUriComplete
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// `POST /v1/auth/device/start` request body. The device's `X-Sphynx-Device`
/// header identifies the install; an optional label names it on the approval page.
public struct DeviceAuthStartRequest: Codable, Hashable, Sendable {
    /// Optional human label for the device, shown to the approving user
    /// (e.g. "Living Room TV"). The client may send the device/app name.
    public var label: String?

    public init(label: String? = nil) {
        self.label = label
    }
}

/// `POST /v1/auth/device/token` request body — the device polls with its
/// `deviceCode`. Returns a `TokenResponse` once approved; until then the error
/// envelope carries code `authorization_pending` (keep polling), `slow_down`
/// (poll less often), `expired_token`, or `access_denied`.
public struct DeviceTokenRequest: Codable, Hashable, Sendable {
    public var deviceCode: String

    public init(deviceCode: String) {
        self.deviceCode = deviceCode
    }
}

/// `POST /v1/auth/device/approve` request body — the authenticated user approves a
/// pending device by the `userCode` they entered or scanned. **204** on success.
public struct DeviceApproveRequest: Codable, Hashable, Sendable {
    public var userCode: String

    public init(userCode: String) {
        self.userCode = userCode
    }
}

/// `GET /v1/auth/device/pending?code=<userCode>` response (authenticated) — lets the
/// approval UI confirm *which* device it's about to authorize before the user taps
/// approve. **404** if the code is unknown or expired.
public struct DevicePendingResponse: Codable, Hashable, Sendable {
    /// The device's self-reported label, if it sent one (e.g. "Living Room TV").
    public var label: String?
    /// Seconds until the request expires.
    public var expiresIn: Double

    public init(label: String? = nil, expiresIn: Double) {
        self.label = label
        self.expiresIn = expiresIn
    }
}
