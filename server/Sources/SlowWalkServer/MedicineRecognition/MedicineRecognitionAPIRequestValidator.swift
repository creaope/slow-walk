import Foundation
import SlowWalkAPIContracts

struct ValidatedMedicineRecognitionRequest: Sendable, Equatable {
    let image: VisionImagePayload
    let requestID: UUID
}

enum MedicineRecognitionRequestValidationFailure:
    Error,
    Sendable,
    Equatable
{
    case invalidFields([APIErrorDetailDTO])
    case imageTooLarge
}

struct MedicineRecognitionAPIRequestValidator: Sendable {
    static let maximumRequestBodyBytes = 6 * 1_024 * 1_024
    static let maximumDecodedImageBytes = 4 * 1_024 * 1_024
    static let maximumEncodedImageCharacters =
        ((maximumDecodedImageBytes + 2) / 3) * 4
    static let allowedMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
    ]

    func validate(
        _ request: MedicineRecognitionAPIRequestDTO
    ) throws -> ValidatedMedicineRecognitionRequest {
        var details = [APIErrorDetailDTO]()
        let mimeType = request.mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.allowedMimeTypes.contains(mimeType) else {
            details.append(
                APIErrorDetailDTO(
                    field: "mimeType",
                    code: "unsupported",
                    message: "Use image/jpeg, image/png, or image/webp."
                )
            )
            throw MedicineRecognitionRequestValidationFailure
                .invalidFields(details)
        }

        let encodedImage = request.imageBase64
        guard !encodedImage.isEmpty else {
            details.append(
                APIErrorDetailDTO(
                    field: "imageBase64",
                    code: "required",
                    message: "Provide one non-empty Base64 image."
                )
            )
            throw MedicineRecognitionRequestValidationFailure
                .invalidFields(details)
        }
        guard encodedImage.count <= Self.maximumEncodedImageCharacters else {
            throw MedicineRecognitionRequestValidationFailure.imageTooLarge
        }
        guard let imageData = Data(base64Encoded: encodedImage) else {
            details.append(
                APIErrorDetailDTO(
                    field: "imageBase64",
                    code: "invalid_base64",
                    message: "The image must use strict Base64 encoding."
                )
            )
            throw MedicineRecognitionRequestValidationFailure
                .invalidFields(details)
        }
        guard !imageData.isEmpty else {
            details.append(
                APIErrorDetailDTO(
                    field: "imageBase64",
                    code: "required",
                    message: "Provide one non-empty Base64 image."
                )
            )
            throw MedicineRecognitionRequestValidationFailure
                .invalidFields(details)
        }
        guard imageData.count <= Self.maximumDecodedImageBytes else {
            throw MedicineRecognitionRequestValidationFailure.imageTooLarge
        }

        return ValidatedMedicineRecognitionRequest(
            image: VisionImagePayload(
                data: imageData,
                mimeType: mimeType
            ),
            requestID: request.requestID
        )
    }
}
