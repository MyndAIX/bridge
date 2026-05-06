---
from: lobster
to: mack
type: task
subject: "Build photo annotation overlay for daily reports"
task_id: T-055
priority: P1
risk_level: medium
repo: "~/Desktop/FieldVision"
branch: "feature/photo-annotations"
created: "2026-03-22T14:00:00Z"
objective: "Add a drawing overlay to photos in daily reports so users can circle defects, add arrows, and write text annotations directly on job site photos."
scope:
  in:
    - "FieldVision/Views/Reports/PhotoAnnotationView.swift"
    - "FieldVision/Views/Reports/DailyReportPhotoSection.swift"
    - "FieldVision/Models/Annotation.swift"
  out:
    - "Supabase sync layer"
    - "Push notifications"
    - "Any server-side changes"
done_criteria:
  - "User can draw freehand lines on a photo"
  - "User can add arrow annotations"
  - "User can add text labels"
  - "Annotations persist in SwiftData"
  - "Existing photo flow is not broken"
  - "No new build warnings"
escalation: "Ask the user if annotation types beyond draw/arrow/text are needed"
context_files:
  - "docs/research/competitive_teardown_2026_03.md"
  - "FieldVision/CLAUDE.md"
related_tasks:
  - T-048
  - T-046
---

# Build photo annotation overlay for daily reports

Users have requested the ability to annotate job site photos directly in the daily report flow. This is one of the top 3 feature requests from beta testers.

## Technical Notes

- Use PencilKit for the drawing canvas
- Layer the canvas over the photo using a ZStack
- Store annotations as serialized PKDrawing data in SwiftData
- Keep the annotation model simple — we'll add more types later

## Acceptance Test

1. Open a daily report
2. Tap a photo to expand it
3. Tap the annotation icon (pencil)
4. Draw on the photo
5. Save — annotation persists when you reopen
