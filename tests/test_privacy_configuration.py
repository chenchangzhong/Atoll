import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENTS = ROOT / "DynamicIsland" / "DynamicIsland.entitlements"
PROJECT = ROOT / "DynamicIsland.xcodeproj" / "project.pbxproj"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class PrivacyConfigurationTests(unittest.TestCase):
    def test_camera_capture_is_explicitly_entitled(self):
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertTrue(entitlements.get("com.apple.security.device.camera"))

    def test_notes_automation_removed_from_apple_events(self):
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertNotIn(
            "com.apple.Notes",
            entitlements["com.apple.security.temporary-exception.apple-events"],
        )

    def test_automation_usage_text_names_spotify_and_music(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count(
                'INFOPLIST_KEY_NSAppleEventsUsageDescription = "Atoll uses AppleScripts to control Spotify and Apple Music.";'
            ),
        )

    def test_reminders_and_calendar_permissions_removed(self):
        project = PROJECT.read_text()

        self.assertEqual(
            0,
            project.count("INFOPLIST_KEY_NSRemindersFullAccessUsageDescription ="),
        )
        self.assertEqual(
            0,
            project.count("ENABLE_RESOURCE_ACCESS_CALENDARS = YES;"),
        )
        self.assertEqual(
            0,
            project.count("INFOPLIST_KEY_NSLocationWhenInUseUsageDescription ="),
        )

    def test_release_resigning_preserves_archived_entitlements(self):
        workflow = RELEASE_WORKFLOW.read_text()

        self.assertIn(
            'codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PATH"',
            workflow,
        )
        self.assertIn('--entitlements "$ENTITLEMENTS_PATH"', workflow)
        self.assertIn(
            'FINAL_ENTITLEMENTS_PATH="$RUNNER_TEMP/${APP_NAME}-final.entitlements"',
            workflow,
        )
        self.assertIn(
            'codesign -d --entitlements :- "$APP_PATH" > "$FINAL_ENTITLEMENTS_PATH"',
            workflow,
        )
        self.assertIn(
            '/usr/libexec/PlistBuddy -c "Print :com.apple.security.device.camera" "$FINAL_ENTITLEMENTS_PATH" | grep -qx "true"',
            workflow,
        )
        self.assertIn(
            '/usr/libexec/PlistBuddy -c "Print :com.apple.security.automation.apple-events" "$FINAL_ENTITLEMENTS_PATH" | grep -qx "true"',
            workflow,
        )

    def test_ci_checks_the_privacy_configuration(self):
        workflow = CI_WORKFLOW.read_text()

        self.assertIn("python3 -m unittest tests.test_privacy_configuration", workflow)


if __name__ == "__main__":
    unittest.main()
