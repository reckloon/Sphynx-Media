import Hummingbird
import SphynxProtocol

// The Sphynx protocol package is deliberately Foundation-only — it knows nothing
// about Hummingbird. We bridge the wire types into Hummingbird's response
// machinery HERE, in the server, by conforming them to `ResponseEncodable`.
// Request bodies need only `Decodable` (which the protocol types already are) for
// `request.decode(as:context:)`.
//
// This keeps the contract dependency-free while letting route handlers return
// the protocol types directly — so the server cannot drift from the wire format.

extension ServerInfo: @retroactive ResponseEncodable {}
extension ErrorEnvelope: @retroactive ResponseEncodable {}
extension TokenResponse: @retroactive ResponseEncodable {}
extension MeResponse: @retroactive ResponseEncodable {}
extension Item: @retroactive ResponseEncodable {}
extension ResolveDescriptor: @retroactive ResponseEncodable {}
extension LibrariesResponse: @retroactive ResponseEncodable {}
extension ItemsResponse: @retroactive ResponseEncodable {}
extension HomeResponse: @retroactive ResponseEncodable {}
extension PlaystateResponse: @retroactive ResponseEncodable {}
extension PlaystateBatchResponse: @retroactive ResponseEncodable {}
extension MarkersInfo: @retroactive ResponseEncodable {}
