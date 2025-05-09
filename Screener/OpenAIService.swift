import Foundation
import AppKit // For NSImage

class OpenAIService {
    static let shared = OpenAIService()
    private init() {}

    private let openAIAPIURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    enum OpenAIError: Error {
        case invalidImageData
        case imageResizingFailed
        case apiError(String)
        case requestFailed(Error)
        case invalidResponse
        case apiKeyMissing
    }

    func analyzeImage(filePath: String, apiKey: String, completion: @escaping (Result<String, OpenAIError>) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(.apiKeyMissing))
            return
        }

        // Enhanced logging for file path and accessibility
        print("OpenAIService: Attempting to load image from filePath: \(filePath)")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: filePath) {
            print("OpenAIService: Error - File does NOT exist at path: \(filePath)")
            completion(.failure(.invalidImageData))
            return
        }
        if !fileManager.isReadableFile(atPath: filePath) {
            print("OpenAIService: Error - File is NOT readable at path: \(filePath)")
            // This often points to a Sandbox permission issue
            completion(.failure(.invalidImageData))
            return
        }
        print("OpenAIService: File exists and is reported as readable.")

        // 1. Load Image
        guard let image = NSImage(contentsOfFile: filePath) else {
            print("OpenAIService: Error - NSImage(contentsOfFile:) returned nil for path: \(filePath)")
            completion(.failure(.invalidImageData))
            return
        }
        print("OpenAIService: NSImage loaded successfully.")

        // 2. Resize and Convert to Data (e.g., JPEG for smaller size)
        //    Aim for max dimension (e.g., 2048px) and reasonable quality.
        //    OpenAI's gpt-4o supports various detail levels, low detail is cheaper & faster.
        //    For file naming, high detail might not be strictly necessary. Let's use "low" detail for now.
        //    Max size for "low" detail is 512x512. If larger, it's scaled down.
        //    If we need higher res, we can adjust.

        let maxDimension: CGFloat = 512.0 // For "low" detail mode in OpenAI
        let imageSize = image.size
        var newSize = imageSize

        if imageSize.width > maxDimension || imageSize.height > maxDimension {
            if imageSize.width > imageSize.height {
                newSize.width = maxDimension
                newSize.height = (imageSize.height / imageSize.width) * maxDimension
            } else {
                newSize.height = maxDimension
                newSize.width = (imageSize.width / imageSize.height) * maxDimension
            }
        }
        
        guard let resizedImage = image.resized(to: newSize),
              let imageData = resizedImage.jpegData(compressionQuality: 0.7) else { // JPEG, 70% quality
            completion(.failure(.imageResizingFailed))
            return
        }
        
        // Check file size before base64 encoding (OpenAI has limits, e.g., 20MB per image for gpt-4-turbo)
        // For gpt-4o-mini, it's likely similar. Let's assume 4MB as a safe base64 string size.
        // Raw image data should be less. 20MB for the image itself.
        // Base64 encoding increases size by ~33%. So if imageData is > 15MB, it might be too big.
        // For "low" detail 512x512, this should not be an issue.

        // 3. Base64 Encode
        let base64Image = imageData.base64EncodedString()

        // 4. Prepare Request
        var request = URLRequest(url: openAIAPIURL)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "gpt-4o-mini", // Specify the model
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "Describe this screenshot in 2-5 words to be used as a concise and descriptive file name. Focus on the main subject or action. Give someone all the context they'd need to identify this screenshot."
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64Image)",
                                "detail": "low" // Use "low" to save tokens and speed up, good for filename generation
                            ]
                        ]
                    ]
                ]
            ],
            "max_tokens": 30 // Max tokens for the filename suggestion
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(.failure(.apiError("Failed to serialize request: \(error.localizedDescription)")))
            return
        }

        // 5. Make API Call
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.requestFailed(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.apiError("Invalid response object.")))
                    return
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    var errorMessage = "API Error: Status Code \(httpResponse.statusCode)."
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        errorMessage += " Body: \(errorBody)"
                    }
                    completion(.failure(.apiError(errorMessage)))
                    return
                }

                guard let data = data else {
                    completion(.failure(.invalidResponse))
                    return
                }

                // 6. Parse Response
                do {
                    if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let choices = jsonResponse["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        completion(.failure(.invalidResponse))
                    }
                } catch {
                    completion(.failure(.apiError("Failed to parse response: \(error.localizedDescription)")))
                }
            }
        }.resume()
    }
}

// Helper extension for NSImage resizing
extension NSImage {
    func resized(to newSize: NSSize) -> NSImage? {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .sourceOver,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiffRepresentation = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
} 
