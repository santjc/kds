import Foundation

public struct ListeningEndpoint: Identifiable, Hashable, Sendable {
  public var id: String { "\(pid):\(port)" }

  public let port: UInt16
  public let pid: Int32
  public let ownerUID: UInt32
  public let userName: String?
  public let processName: String
  public let addresses: Set<String>

  public init(
    port: UInt16,
    pid: Int32,
    ownerUID: UInt32,
    userName: String? = nil,
    processName: String,
    addresses: Set<String> = []
  ) {
    self.port = port
    self.pid = pid
    self.ownerUID = ownerUID
    self.userName = userName
    self.processName = processName
    self.addresses = addresses
  }
}

public struct ProcessDetails: Hashable, Sendable {
  public let executablePath: String?
  public let workingDirectory: String?
  public let projectRoot: String?

  public var projectName: String? {
    projectRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  public init(executablePath: String?, workingDirectory: String?, projectRoot: String?) {
    self.executablePath = executablePath
    self.workingDirectory = workingDirectory
    self.projectRoot = projectRoot
  }
}

public enum EndpointCategory: String, Codable, Sendable {
  case development
  case other
  case protected
}

public struct ProcessClassification: Hashable, Sendable {
  public let category: EndpointCategory
  public let reason: String

  public init(category: EndpointCategory, reason: String) {
    self.category = category
    self.reason = reason
  }
}

public struct DisplayEndpoint: Identifiable, Hashable, Sendable {
  public var id: String { endpoint.id }

  public let endpoint: ListeningEndpoint
  public let details: ProcessDetails
  public let classification: ProcessClassification

  public init(
    endpoint: ListeningEndpoint,
    details: ProcessDetails,
    classification: ProcessClassification
  ) {
    self.endpoint = endpoint
    self.details = details
    self.classification = classification
  }
}
