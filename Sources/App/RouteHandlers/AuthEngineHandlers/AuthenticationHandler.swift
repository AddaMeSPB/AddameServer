import Vapor
import Fluent
import AddaSharedModels
import VaporRouting
import BSON
import JWT
import MongoKitten

public func authenticationHandler(
    request: Request,
    route: AuthenticationRoute
) async throws -> AsyncResponseEncodable {
    switch route {

    case .loginViaEmail(let input):

        if !input.email.isEmailValid {
            throw Abort(.badRequest, reason: "your email is not valied")
        }

        let email = input.email.lowercased()
        let code = String.randomDigits(ofLength: 6)
        let message = "\(code)"

        switch request.application.environment {
        case .production:

            try await request
                .emailVerifier
                .verifyOTPEmail(for: email, msg: message)

            let smsAttempt = VerificationCodeAttempt(
                email: email,
                code: code,
                expiresAt: Date().addingTimeInterval(5.0 * 60.0)
            )

            _ = try await smsAttempt.save(on: request.db).get()
            let attemptId = try! smsAttempt.requireID()
            return EmailLoginOutput(
                email: email,
                attemptId: attemptId
            )

        case .development:

            let code = "336699"
//            try await request
//                .emailVerifier
//                .verifyOTPEmail(for: input.email, msg: code)

            let smsAttempt = VerificationCodeAttempt(
                email: email,
                code: code,
                expiresAt: Date().addingTimeInterval(5.0 * 60.0)
            )
            _ = try await smsAttempt.save(on: request.db).get()

            let attemptId = try! smsAttempt.requireID()
            return EmailLoginOutput(
                email: email,
                attemptId: attemptId
            )

        default:

            let code = "336699"

            let smsAttempt = VerificationCodeAttempt(
                email: email,
                code: code,
                expiresAt: Date().addingTimeInterval(5.0 * 60.0)
            )
            _ = try await smsAttempt.save(on: request.db).get()

            let attemptId = try! smsAttempt.requireID()
            return EmailLoginOutput(
                email: email,
                attemptId: attemptId
            )
        }

    case .verifyEmail(let input):

        guard let attempt = try await VerificationCodeAttempt.query(on: request.db)
            .filter(\.$id == input.attemptId)
            .filter(\.$email == input.email.lowercased())
            .filter(\.$code == input.code)
            .first()
            .get()

        else {
            throw Abort(.notFound, reason: "\(#line) VerificationCodeAttempt not found!")
        }

            guard let expirationDate = attempt.expiresAt else {
                throw Abort(.notFound, reason: "\(#line) code expired")
            }

            guard expirationDate > Date() else {
                throw Abort(.notFound, reason: "\(#line) expiration date over")
            }

        let res = try await emailVerificationResponseForValidUser(with: input, on: request)

        return res

    case .refreshToken(input: let data):

        let refreshTokenFromData = data.refreshToken
        let jwtPayload: JWTRefreshToken = try request.application
            .jwt.signers.verify(refreshTokenFromData, as: JWTRefreshToken.self)

        guard let userID = jwtPayload.id else {
            throw Abort(.notFound, reason: "User id missing from RefreshToken")
        }

        guard let user = try await UserModel.query(on: request.db)
            .filter(\.$id == userID)
            .first()
            .get()
        else {
            throw Abort(.notFound, reason: "User not found by id: \(userID) for refresh token")
        }

        let payload = try Payload(with: user)
        let refreshPayload = JWTRefreshToken(user: user)

        do {
            let refreshToken = try request.application.jwt.signers.sign(refreshPayload)
            let payloadString = try request.application.jwt.signers.sign(payload)
            return RefreshTokenResponse(accessToken: payloadString, refreshToken: refreshToken)
        } catch {
            throw Abort(.notFound, reason: "jwt signers error: \(error)")
        }
    }
}

private func findUserResponse(
    with phoneNumber: String,
    on req: Request) async throws -> UserModel? {

    try await UserModel.query(on: req.db)
        .with(\.$attachments)
        .filter(\.$phoneNumber == phoneNumber)
        .first()
        .get()
}

private func emailVerificationResponseForValidUser(
    with input: VerifyEmailInput,
    on req: Request) async throws -> SuccessfulLoginResponse {

        let email = input.email

        let createNewUser = UserModel()
        createNewUser.email = input.email
        createNewUser.fullName = input.niceName
        createNewUser.role = .basic
        createNewUser.language = .english
        createNewUser.isEmailVerified = true
        createNewUser.passwordHash = "-"
        createNewUser.phoneNumber = "-"

        if try await req.users.find(email: email) == nil {
            try await createNewUser.save(on: req.db).get()
        }

        guard let user = try await req.users.find(email: email) else {
            throw Abort(.notFound, reason: "User not found")
        }

        do {
            let userPayload = try Payload(with: user)
            let refreshPayload = JWTRefreshToken(user: user)

            let accessToken = try req.application.jwt.signers.sign(userPayload)
            let refreshToken = try req.application.jwt.signers.sign(refreshPayload)

            let access = RefreshTokenResponse(accessToken: accessToken, refreshToken: refreshToken)
            req.payload = userPayload

            try await VerificationCodeAttempt.query(on: req.db)
                .filter(\.$id == input.attemptId)
                .filter(\.$email == input.email)
                .filter(\.$code == input.code)
                .delete(force: true)

            return SuccessfulLoginResponse(status: "ok", user: user.mapGet(),  access: access)
        } catch {
            throw Abort(.notFound, reason: error.localizedDescription)
        }

}

// MARK: - Login Response for mobile auth

public struct SuccessfulLoginResponse: Codable {
    public let status: String
    public let user: UserOutput
    public let access: RefreshTokenResponse

    public init(
      status: String,
      user: UserOutput,
      access: RefreshTokenResponse
    ) {
      self.status = status
      self.user = user
      self.access = access
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.user == rhs.user
      && lhs.access.accessToken == rhs.access.accessToken
    }
}

extension SuccessfulLoginResponse: Equatable {}
