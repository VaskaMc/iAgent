import Foundation

#if canImport(MapKit)
import MapKit
#endif

public enum MapsTransportMode: String, Codable, Sendable, Equatable {
    case driving
    case walking
    case transit
}

public struct MapDestinationCandidate: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let latitude: Double
    public let longitude: Double

    public init(id: String, name: String, subtitle: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum MapsActionOutcome: Equatable, Sendable {
    case handedOffToMaps(destination: MapDestinationCandidate, mode: MapsTransportMode)
    case disambiguationRequired(query: String, candidates: [MapDestinationCandidate])
    case notFound(query: String)
}

public protocol MapsSearchAndHandoffProtocol: Sendable {
    func searchPlaces(query: String) async throws -> [MapDestinationCandidate]
    func openInMaps(destination: MapDestinationCandidate, mode: MapsTransportMode) async -> Bool
}

public final class InMemoryMapsBackend: MapsSearchAndHandoffProtocol, @unchecked Sendable {
    public var placesByQuery: [String: [MapDestinationCandidate]] = [:]
    public var locationPermissionRequested = false
    public var lastOpenedDestination: MapDestinationCandidate?
    public var lastOpenedMode: MapsTransportMode?

    public init(placesByQuery: [String: [MapDestinationCandidate]] = [:]) {
        self.placesByQuery = placesByQuery
    }

    public func searchPlaces(query: String) async throws -> [MapDestinationCandidate] {
        placesByQuery[query] ?? []
    }

    public func openInMaps(destination: MapDestinationCandidate, mode: MapsTransportMode) async -> Bool {
        lastOpenedDestination = destination
        lastOpenedMode = mode
        return true
    }
}

#if canImport(MapKit)
public final class LiveMapKitBackend: MapsSearchAndHandoffProtocol, @unchecked Sendable {
    public init() {}

    public func searchPlaces(query: String) async throws -> [MapDestinationCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(5).enumerated().map { idx, item in
            let coord = item.placemark.coordinate
            return MapDestinationCandidate(
                id: "mk-\(idx)",
                name: item.name ?? query,
                subtitle: item.placemark.title ?? "",
                latitude: coord.latitude,
                longitude: coord.longitude
            )
        }
    }

    @MainActor
    public func openInMaps(destination: MapDestinationCandidate, mode: MapsTransportMode) async -> Bool {
        let placemark = MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
        )
        let item = MKMapItem(placemark: placemark)
        item.name = destination.name

        let directionsMode: String
        switch mode {
        case .driving: directionsMode = MKLaunchOptionsDirectionsModeDriving
        case .walking: directionsMode = MKLaunchOptionsDirectionsModeWalking
        case .transit: directionsMode = MKLaunchOptionsDirectionsModeTransit
        }
        let options = [MKLaunchOptionsDirectionsModeKey: directionsMode]
        #if os(iOS)
        return await item.openInMaps(launchOptions: options, from: nil)
        #else
        return await item.openInMaps(launchOptions: options)
        #endif
    }
}
#endif

/// Doğrulanmış hedefi ve ulaşım türünü Haritalar'a aktarır; yalnız hedef açmak için konum izni istemez.
public final class MapsActionExecutor: @unchecked Sendable {
    private let backend: MapsSearchAndHandoffProtocol

    public init(backend: MapsSearchAndHandoffProtocol) {
        self.backend = backend
    }

    public func openDirections(
        query: String,
        transportMode: MapsTransportMode = .transit
    ) async -> MapsActionOutcome {
        do {
            let candidates = try await backend.searchPlaces(query: query)
            if candidates.isEmpty {
                return .notFound(query: query)
            }
            if candidates.count > 1 {
                return .disambiguationRequired(query: query, candidates: candidates)
            }
            _ = await backend.openInMaps(destination: candidates[0], mode: transportMode)
            return .handedOffToMaps(destination: candidates[0], mode: transportMode)
        } catch {
            return .notFound(query: query)
        }
    }
}
