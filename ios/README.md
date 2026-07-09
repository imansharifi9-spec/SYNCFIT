# SyncFit iOS App

Native SwiftUI iOS app for SyncFit — Milestone 1 foundation + MVP screen shell.

## Requirements

- **macOS** with **Xcode 15+** (iOS apps require a Mac to build and run)
- iOS 17.0+ deployment target
- Apple Developer account (for device testing and App Store)

> You're currently on Windows. Copy this project to a Mac (or use iCloud/Git) and open it in Xcode to run the app.

## Open the Project

1. Copy `SyncFit` folder to your Mac
2. Open `ios/SyncFit.xcodeproj` in Xcode
3. Select an iPhone simulator (e.g. iPhone 15)
4. Press **Cmd+R** to build and run

## What's Built

| Screen | Status |
|--------|--------|
| Sign in / Sign up | UI shell (no backend yet) |
| Onboarding (goals, macros, coach) | Functional flow |
| Home dashboard | Stats + SyncFit+ preview |
| Workout logging | Log workouts from exercise library, view history, swipe to delete |
| Nutrition tracking | Log food, edit entries, create reusable meals, daily macro totals |
| Progress | Weight logging, history, photo placeholder |
| Coach search | Browse coaches, data permission toggles |
| Settings | Profile, theme (light/dark), subscription, sign out |

Data is persisted locally with **SwiftData** — workouts, nutrition, weight, profile, and onboarding state survive app restarts. No cloud backend yet.

## Project Structure

```
ios/
├── SyncFit.xcodeproj/
└── SyncFit/
    ├── SyncFitApp.swift          # App entry
    ├── AppState.swift            # Auth + onboarding state
    ├── Models/                   # User models + SwiftData persistence models
    ├── Services/                 # FitnessDataStore, SampleDataSeeder
    ├── Theme/                    # Colors, buttons, cards
    └── Views/
        ├── Auth/
        ├── Onboarding/
        ├── Home/
        ├── Workouts/
        ├── Nutrition/
        ├── Progress/
        ├── Coaches/
        └── Settings/
```

## Next Development Milestones

Aligned with `docs/execution-plan.md`:

1. **Backend** — Supabase or Firebase for auth, database, storage
2. ~~**Persistence** — SwiftData or Core Data for offline caching~~ ✅ SwiftData (local)
3. ~~**Exercise library** — Seed database of exercises~~ ✅ 40+ exercises seeded
4. **Food database** — Integrate nutrition API (USDA, Nutritionix)
5. **Coach messaging** — Real-time chat
6. **Payments** — StoreKit 2 for SyncFit+, Stripe for coach subscriptions
7. **Progress photos** — Cloud storage with user permission controls

## App Store Checklist (Later)

- [ ] Apple Developer Program ($99/year)
- [ ] App icon (1024×1024)
- [ ] Privacy policy URL
- [ ] Terms of service
- [ ] App Store screenshots
- [ ] TestFlight beta

## Bundle ID

Default: `com.syncfit.app` — change in Xcode → Target → Signing & Capabilities if needed.
