import Foundation
import AgentCore

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

public protocol ETACalculatingBackendProtocol: Sendable {
    func estimateTravelMinutes(destinationQuery: String, mode: MapsTransportMode) async -> Int?
}

public final class InMemoryMapsBackend: MapsSearchAndHandoffProtocol, ETACalculatingBackendProtocol, @unchecked Sendable {
    public var placesByQuery: [String: [MapDestinationCandidate]] = [:]
    public var etaMinutesByQuery: [String: Int] = [:]
    public var etaMinutesByDestinationId: [String: Int] = [:]
    public var defaultEstimatedMinutes: Int?
    public var locationPermissionRequested = false
    public var lastOpenedDestination: MapDestinationCandidate?
    public var lastOpenedMode: MapsTransportMode?

    public init(
        placesByQuery: [String: [MapDestinationCandidate]] = [:],
        etaMinutesByQuery: [String: Int] = [:],
        etaMinutesByDestinationId: [String: Int] = [:],
        defaultEstimatedMinutes: Int? = nil
    ) {
        self.placesByQuery = placesByQuery
        self.etaMinutesByQuery = etaMinutesByQuery
        self.etaMinutesByDestinationId = etaMinutesByDestinationId
        self.defaultEstimatedMinutes = defaultEstimatedMinutes
    }

    public func searchPlaces(query: String) async throws -> [MapDestinationCandidate] {
        placesByQuery[query] ?? []
    }

    public func openInMaps(destination: MapDestinationCandidate, mode: MapsTransportMode) async -> Bool {
        lastOpenedDestination = destination
        lastOpenedMode = mode
        return true
    }

    public func estimateTravelMinutes(destinationQuery: String, mode: MapsTransportMode) async -> Int? {
        if let exact = etaMinutesByQuery[destinationQuery] {
            return exact
        }
        let normalizedQuery = TurkicTextNormalizer.normalize(destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        if let normalizedMatch = etaMinutesByQuery.first(where: {
            TurkicTextNormalizer.normalize($0.key.trimmingCharacters(in: .whitespacesAndNewlines)) == normalizedQuery
        })?.value {
            return normalizedMatch
        }
        if let candidate = placesByQuery[destinationQuery]?.first,
           let byId = etaMinutesByDestinationId[candidate.id] {
            return byId
        }
        return defaultEstimatedMinutes
    }
}

#if canImport(MapKit)
public final class LiveMapKitBackend: MapsSearchAndHandoffProtocol, ETACalculatingBackendProtocol, @unchecked Sendable {
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

    public func estimateTravelMinutes(destinationQuery: String, mode: MapsTransportMode) async -> Int? {
        let trimmed = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = trimmed
            let searchResponse = try await MKLocalSearch(request: searchRequest).start()
            guard let destinationItem = searchResponse.mapItems.first else {
                return nil
            }
            let directionsRequest = MKDirections.Request()
            directionsRequest.source = MKMapItem.forCurrentLocation()
            directionsRequest.destination = destinationItem
            switch mode {
            case .driving: directionsRequest.transportType = .automobile
            case .walking: directionsRequest.transportType = .walking
            case .transit: directionsRequest.transportType = .transit
            }
            let etaResponse = try await MKDirections(request: directionsRequest).calculateETA()
            return max(1, Int((etaResponse.expectedTravelTime / 60.0).rounded()))
        } catch {
            // Konum izni veya ağ olmadığında güvenli geri çekilme; asla konum izni istemez.
            return nil
        }
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

    public func estimateTravelMinutes(
        destinationQuery: String,
        mode: MapsTransportMode = .driving
    ) async -> Int? {
        let trimmed = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let etaBackend = backend as? ETACalculatingBackendProtocol {
            return await etaBackend.estimateTravelMinutes(destinationQuery: trimmed, mode: mode)
        }
        return nil
    }
}
