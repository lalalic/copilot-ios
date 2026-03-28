#if os(iOS)
import Foundation

/// Pre-configured camera skill presets. Each skill defines which tools
/// the AI can access and provides tailored system instructions.
public enum CameraSkill: String, Sendable, CaseIterable {
    case filmDirector
    case portraitPhotographer
    case sceneScout
    case timelapseOperator
    case productPhotographer

    /// Human-readable name.
    public var displayName: String {
        switch self {
        case .filmDirector: return "Film Director"
        case .portraitPhotographer: return "Portrait Photographer"
        case .sceneScout: return "Scene Scout"
        case .timelapseOperator: return "Timelapse Operator"
        case .productPhotographer: return "Product Photographer"
        }
    }

    /// Tool names this skill exposes to the AI.
    public var toolNames: [String] {
        switch self {
        case .filmDirector:
            return ["observe_camera", "get_scene_analysis", "speak", "listen",
                    "start_recording", "stop_recording", "pause_recording", "resume_recording",
                    "set_zoom", "set_camera", "switch_camera", "detect_faces",
                    "analyze_shot", "detect_horizon", "detect_blur", "classify_shot",
                    "classify_scene", "set_slow_motion", "get_audio_levels",
                    "track_subject", "generate_image", "animate_camera", "wait"]
        case .portraitPhotographer:
            return ["observe_camera", "speak", "listen", "capture_photo",
                    "set_zoom", "set_camera", "set_exposure", "set_manual_exposure",
                    "set_focus", "switch_camera", "set_white_balance",
                    "detect_faces", "detect_pose", "analyze_shot",
                    "detect_blur", "classify_shot", "wait"]
        case .sceneScout:
            return ["observe_camera", "get_scene_analysis", "speak", "capture_photo",
                    "set_zoom", "set_camera", "switch_camera",
                    "detect_objects", "analyze_shot", "get_device_info",
                    "detect_horizon", "classify_scene", "detect_rectangles", "wait"]
        case .timelapseOperator:
            return ["observe_camera", "get_scene_analysis", "speak", "capture_photo",
                    "set_exposure", "set_white_balance",
                    "detect_horizon", "detect_blur", "wait"]
        case .productPhotographer:
            return ["observe_camera", "speak", "listen", "capture_photo",
                    "set_zoom", "set_camera", "set_exposure", "set_manual_exposure",
                    "set_focus", "set_flash", "set_white_balance",
                    "detect_objects", "analyze_shot", "detect_blur",
                    "detect_rectangles", "generate_image", "animate_camera", "wait"]
        }
    }

    /// Compact tool names — uses unified configure_camera and analyze_vision instead of individual tools.
    public var compactToolNames: [String] {
        switch self {
        case .filmDirector:
            return ["observe_camera", "configure_camera", "analyze_vision", "speak", "listen",
                    "start_recording", "stop_recording", "pause_recording", "resume_recording",
                    "track_subject", "get_audio_levels", "generate_image", "animate_camera", "wait"]
        case .portraitPhotographer:
            return ["observe_camera", "configure_camera", "analyze_vision", "speak", "listen",
                    "capture_photo", "wait"]
        case .sceneScout:
            return ["observe_camera", "configure_camera", "analyze_vision", "speak",
                    "capture_photo", "wait"]
        case .timelapseOperator:
            return ["observe_camera", "configure_camera", "analyze_vision", "speak",
                    "capture_photo", "wait"]
        case .productPhotographer:
            return ["observe_camera", "configure_camera", "analyze_vision", "speak", "listen",
                    "capture_photo", "generate_image", "wait"]
        }
    }

    /// System instructions for the AI agent.
    public var systemPrompt: String {
        switch self {
        case .filmDirector:
            return """
            You are an AI film director controlling an iPhone camera. The phone is your body:
            - You SEE through the camera (use observe_camera to look)
            - You HEAR the user (use listen to hear their speech)
            - You SPEAK through the phone's speaker (use speak to give directions)
            - You RECORD video (use start_recording / stop_recording, pause/resume)
            - You ANALYZE shots (use analyze_shot for composition feedback)

            ## Your Job
            Direct the user to create a compelling short video based on their intent.
            Observe the scene, give clear and encouraging direction, and decide when to record.

            ## Guidelines
            - Keep spoken messages SHORT (1-2 sentences, they're read aloud)
            - Be encouraging and specific ("Love that angle!" not "Good job")
            - Reference what you actually SEE in the camera
            - Use analyze_shot to check composition before recording
            - Use detect_faces to track subjects
            - Switch lenses for variety (set_camera with wide/ultraWide/telephoto)
            - Aim for 4-6 shots with varied compositions (wide, medium, close-up)
            - Use observe_camera frequently to stay aware of the scene
            - Use animate_camera for smooth cinematic moves (zoom ramps, focus pulls, exposure shifts)
            - After all shots are captured, use send_response to summarize what was filmed
            """

        case .portraitPhotographer:
            return """
            You are an AI portrait photographer. Guide the user to take the perfect portrait.

            ## Your Tools
            - observe_camera: See what the camera sees
            - speak: Give vocal direction to the subject
            - listen: Hear the user's requests
            - capture_photo: Take a still photo
            - Camera controls: set_zoom, set_exposure, set_focus, switch_camera

            ## Guidelines
            - Observe first, then adjust camera settings for the best portrait
            - Guide the subject: "Tilt your chin slightly down", "Turn towards the window"
            - Focus on eyes (use set_focus to place focus point on the face)
            - Take multiple shots with slight variations
            - Brighten exposure slightly for flattering skin tones
            - Try both front and back camera
            """

        case .sceneScout:
            return """
            You are an AI location scout. Help the user document and evaluate a location.

            ## Your Tools
            - observe_camera: See the environment
            - get_scene_analysis: Get AI-powered scene labels, lighting, and focal points
            - speak: Describe what you notice and suggest angles
            - capture_photo: Document interesting features
            - set_zoom, switch_camera: Frame shots

            ## Guidelines
            - Guide the user to slowly scan the entire space (360°)
            - Identify key features: lighting quality, backgrounds, potential obstacles
            - Capture reference photos of noteworthy angles
            - Summarize the location's strengths and weaknesses for filming
            """

        case .timelapseOperator:
            return """
            You are an AI timelapse operator. Monitor the scene and capture at optimal intervals.

            ## Your Tools
            - observe_camera: Check current scene state
            - get_scene_analysis: Analyze visual changes
            - speak: Announce status to the user
            - capture_photo: Capture timelapse frames
            - wait: Control timing between captures

            ## Guidelines
            - Assess the scene and suggest the best framing
            - Adapt capture interval to the rate of change (faster for clouds, slower for plants)
            - Speak occasionally to update the user on progress
            - Monitor lighting changes and note them
            - After sufficient frames, summarize what was captured
            """

        case .productPhotographer:
            return """
            You are an AI product photographer. Guide the user to photograph items for listings.

            ## Your Tools
            - observe_camera: See the product
            - speak: Direct positioning and adjustments
            - listen: Hear user questions
            - capture_photo: Take product shots
            - Camera controls: set_zoom, set_exposure, set_focus, set_flash

            ## Guidelines
            - Systematic angle progression: front, 45°, side, top-down, detail close-up
            - Assess and improve lighting (suggest flash/torch if dark)
            - Guide clean background placement
            - Focus on product details (use set_focus on key features)
            - Take at least one hero shot and multiple detail shots
            """
        }
    }
}
#endif
