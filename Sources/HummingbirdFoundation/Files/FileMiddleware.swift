#if os(Linux)
import Glibc
#else
import Darwin.C
#endif
import Foundation
import Hummingbird
import NIO

public struct HBFileMiddleware: HBMiddleware {
    let rootFolder: String
    let fileIO: HBFileIO

    public init(_ rootFolder: String = "public", application: HBApplication) {
        var rootFolder = rootFolder
        if rootFolder.last == "/" {
            rootFolder = String(rootFolder.dropLast())
        }
        self.rootFolder = rootFolder
        self.fileIO = .init(application: application)

        let workingFolder: String
        if rootFolder.first == "/" {
            workingFolder = rootFolder
        } else {
            if let cwd = getcwd(nil, Int(PATH_MAX)) {
                workingFolder = String(cString: cwd)
                free(cwd)
            } else {
                workingFolder = "."
            }
        }
        application.logger.info("FileMiddleware serving from \(workingFolder)/\(rootFolder)")
    }

    public func apply(to request: HBRequest, next: HBResponder) -> EventLoopFuture<HBResponse> {
        // if next responder returns a 404 then check if file exists
        return next.respond(to: request).flatMapError { error in
            guard let httpError = error as? HBHTTPError, httpError.status == .notFound else {
                return request.eventLoop.makeFailedFuture(error)
            }

            guard let path = request.uri.path.removingPercentEncoding else {
                return request.eventLoop.makeFailedFuture(HBHTTPError(.badRequest))
            }

            guard !path.contains("..") else {
                return request.eventLoop.makeFailedFuture(HBHTTPError(.badRequest))
            }

            let fullPath = rootFolder + path

            switch request.method {
            case .GET:
                if let rangeHeader = request.headers["Range"].first {
                    guard let range = getRangeFromHeaderValue(rangeHeader) else {
                        return request.failure(.rangeNotSatisfiable)
                    }
                    return fileIO.loadFile(path: fullPath, range: range, context: request.context)
                        .map { body, fileSize in
                            var headers: HTTPHeaders = ["accept-ranges": "bytes"]

                            let lowerBound = max(range.lowerBound, 0)
                            let upperBound = min(range.upperBound, fileSize - 1)
                            headers.replaceOrAdd(name: "content-range", value: "bytes \(lowerBound)-\(upperBound)/\(fileSize)")

                            return HBResponse(status: .partialContent, headers: headers, body: body)
                        }
                }
                return fileIO.loadFile(path: fullPath, context: request.context)
                    .map { body in
                        let headers: HTTPHeaders = ["accept-ranges": "bytes"]
                        return HBResponse(status: .ok, headers: headers, body: body)
                    }

            case .HEAD:
                return fileIO.headFile(path: fullPath, context: request.context)

            default:
                return request.failure(error)
            }
        }
    }
}

extension HBFileMiddleware {
    /// Convert "bytes=value-value" range header into `ClosedRange<Int>`
    ///
    /// Also supports open ended ranges
    func getRangeFromHeaderValue(_ header: String) -> ClosedRange<Int>? {
        let groups = matchRegex(header, expression: "^bytes=([\\d]*)-([\\d]*)$")
        guard groups.count == 3 else { return nil }

        if groups[1] == "" {
            guard let upperBound = Int(groups[2]) else { return nil }
            return Int.min...upperBound
        } else if groups[2] == "" {
            guard let lowerBound = Int(groups[1]) else { return nil }
            return lowerBound...Int.max
        } else {
            guard let lowerBound = Int(groups[1]),
                  let upperBound = Int(groups[2]) else { return nil }
            return lowerBound...upperBound
        }
    }

    private func matchRegex(_ string: String, expression: String) -> [Substring] {
        guard let regularExpression = try? NSRegularExpression(pattern: expression, options: []),
              let firstMatch = regularExpression.firstMatch(in: string, range: NSMakeRange(0, string.count)) else {
            return []
        }

        var groups: [Substring] = []
        groups.reserveCapacity(firstMatch.numberOfRanges)
        for i in 0..<firstMatch.numberOfRanges {
            guard let range = Range(firstMatch.range(at: i), in: string) else { continue }
            groups.append(string[range])
        }
        return groups
    }
}
