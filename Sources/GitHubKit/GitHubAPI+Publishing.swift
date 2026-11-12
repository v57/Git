import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A release as GitHub returns it.
public struct GitHubRelease: Sendable, Hashable, Decodable {
  public var id: Int
  public var tagName: String
  public var name: String?
  public var body: String?
  public var draft: Bool
  public var htmlURL: String
  /// The files already uploaded (GitHub lists them with the release).
  public var assets: [GitHubReleaseAsset]?

  enum CodingKeys: String, CodingKey {
    case id, name, body, draft, assets
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}

/// A file attached to a release.
public struct GitHubReleaseAsset: Sendable, Hashable, Decodable {
  public var id: Int
  public var name: String
  public var size: Int
  public var downloadURL: String

  enum CodingKeys: String, CodingKey {
    case id, name, size
    case downloadURL = "browser_download_url"
  }
}

/// An issue as GitHub returns it.
public struct GitHubIssue: Sendable, Hashable, Decodable {
  public var number: Int
  public var title: String
  public var htmlURL: String

  enum CodingKeys: String, CodingKey {
    case number, title
    case htmlURL = "html_url"
  }
}

/// A repository's Discussions category.
public struct GitHubDiscussionCategory: Sendable, Hashable, Decodable {
  public var id: String
  public var name: String
  public var slug: String
}

/// A discussion as GitHub returns it.
public struct GitHubDiscussion: Sendable, Hashable, Decodable {
  public var id: String
  public var number: Int
  public var url: String
}

private struct GraphQLRequest: Encodable {
  var query: String
  var variables: [String: String]
}

private struct GraphQLAnswer<Response: Decodable>: Decodable {
  struct Failure: Decodable { var message: String }
  var data: Response?
  var errors: [Failure]?
}

/// Telling people about a project: releases, issues and Discussions. The token GitHubKit signs in with (`public_repo`
/// or `repo`) covers them all, with no new scopes.
extension GitHubAPI {
  private struct NewRelease: Encodable {
    var tag_name: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var target_commitish: String?
    var generate_release_notes: Bool
  }

  /// Creates a release, and its tag from `target` (the default branch without one) if the tag is new. With
  /// `generateNotes`, GitHub writes the notes from the commits and pull requests since the last release.
  public func createRelease(
    owner: String, repository: String, tag: String, name: String?, body: String?, draft: Bool = false,
    prerelease: Bool = false, target: String? = nil, generateNotes: Bool = false
  ) async throws -> GitHubRelease {
    try await send(
      "POST", "/repos/\(Self.pathComponent(owner))/\(Self.pathComponent(repository))/releases",
      body: NewRelease(
        tag_name: tag, name: name, body: body, draft: draft, prerelease: prerelease, target_commitish: target,
        generate_release_notes: generateNotes))
  }

  /// Uploads a file to a release as `name` (GitHub's upload host). GitHub refuses a name the release already has:
  /// delete that asset first to replace it.
  public func uploadReleaseAsset(
    owner: String, repository: String, releaseID: Int, name: String, data: Data,
    contentType: String = "application/octet-stream"
  ) async throws -> GitHubReleaseAsset {
    var components = URLComponents(string: "https://uploads.github.com")!
    components.path = "/repos/\(owner)/\(repository)/releases/\(releaseID)/assets"
    components.queryItems = [URLQueryItem(name: "name", value: name)]
    guard let url = components.url else { throw GitHubError.invalidResponse }
    var request = URLRequest.gitHub(url)
    request.httpMethod = "POST"
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    let (body, response) = try await transport.send(request)
    guard (200..<300).contains(response.statusCode) else { throw GitHubError.from(status: response.statusCode, body: body) }
    do {
      return try JSONDecoder().decode(GitHubReleaseAsset.self, from: body)
    } catch {
      throw GitHubError.invalidResponse
    }
  }

  /// Deletes a release's file.
  public func deleteReleaseAsset(owner: String, repository: String, id: Int) async throws {
    _ = try await raw(
      "DELETE", "/repos/\(Self.pathComponent(owner))/\(Self.pathComponent(repository))/releases/assets/\(id)")
  }

  /// The release for `tag`, if there is one.
  public func release(owner: String, repository: String, tag: String) async throws -> GitHubRelease? {
    do {
      let release: GitHubRelease = try await send(
        "GET", "/repos/\(Self.pathComponent(owner))/\(Self.pathComponent(repository))/releases/tags/\(Self.pathComponent(tag))")
      return release
    } catch GitHubError.api(status: 404, _) {
      return nil
    }
  }

  /// Replaces a release's title and notes.
  public func updateRelease(owner: String, repository: String, id: Int, name: String?, body: String?) async throws -> GitHubRelease {
    struct Change: Encodable {
      var name: String?
      var body: String?
    }
    return try await send(
      "PATCH", "/repos/\(Self.pathComponent(owner))/\(Self.pathComponent(repository))/releases/\(id)",
      body: Change(name: name, body: body))
  }

  /// Creates an issue. Labels are dropped silently without push access, which is fine for the owner.
  public func createIssue(owner: String, repository: String, title: String, body: String?, labels: [String] = []) async throws -> GitHubIssue {
    struct NewIssue: Encodable {
      var title: String
      var body: String?
      var labels: [String]
    }
    return try await send(
      "POST", "/repos/\(Self.pathComponent(owner))/\(Self.pathComponent(repository))/issues",
      body: NewIssue(title: title, body: body, labels: labels))
  }

  /// Sends a GraphQL query and decodes its `data`.
  func graphQL<Response: Decodable>(_ query: String, variables: [String: String]) async throws -> Response {
    let answer: GraphQLAnswer<Response> = try await send("POST", "/graphql", body: GraphQLRequest(query: query, variables: variables))
    if let message = answer.errors?.first?.message { throw GitHubError.api(status: 200, message: message) }
    guard let data = answer.data else { throw GitHubError.invalidResponse }
    return data
  }

  /// The repository's GraphQL id and its Discussions categories (empty when Discussions are off).
  public func discussionCategories(owner: String, repository: String) async throws -> (repositoryID: String, categories: [GitHubDiscussionCategory]) {
    struct Nodes: Decodable { var nodes: [GitHubDiscussionCategory] }
    struct Repository: Decodable {
      var id: String
      var discussionCategories: Nodes
    }
    struct Data: Decodable { var repository: Repository }
    let query = """
      query($owner: String!, $name: String!) {
        repository(owner: $owner, name: $name) {
          id
          discussionCategories(first: 25) { nodes { id name slug } }
        }
      }
      """
    let data: Data = try await graphQL(query, variables: ["owner": owner, "name": repository])
    return (data.repository.id, data.repository.discussionCategories.nodes)
  }

  public func createDiscussion(repositoryID: String, categoryID: String, title: String, body: String) async throws -> GitHubDiscussion {
    struct Payload: Decodable { var discussion: GitHubDiscussion }
    struct Data: Decodable { var createDiscussion: Payload }
    let mutation = """
      mutation($repositoryId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
        createDiscussion(input: {repositoryId: $repositoryId, categoryId: $categoryId, title: $title, body: $body}) {
          discussion { id number url }
        }
      }
      """
    let data: Data = try await graphQL(
      mutation, variables: ["repositoryId": repositoryID, "categoryId": categoryID, "title": title, "body": body])
    return data.createDiscussion.discussion
  }
}
