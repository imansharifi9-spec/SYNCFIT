# MVP Feature Backlog

**Status:** Draft — update after Phase 2 validation interviews  
**Last updated:** June 2026

Priority: **P0** = must ship for MVP | **P1** = should ship | **P2** = post-MVP

---

## P0 — Must Have (MVP)

### Account & Onboarding
- [ ] Email/password signup and login
- [ ] Goal selection (muscle, fat loss, performance, general health)
- [ ] Basic fitness info (age, height, weight, experience level)
- [ ] Calorie and macro target setup
- [ ] "Do you currently have a coach?" onboarding branch

### Workout Tracking
- [ ] Exercise search (seed library)
- [ ] Create routines
- [ ] Log sets, reps, weight
- [ ] Workout notes
- [ ] Workout history
- [ ] Basic personal records

### Nutrition Tracking
- [ ] Food search
- [ ] Log meals by time of day
- [ ] Track calories, protein, carbs, fat
- [ ] Custom food creation
- [ ] Daily macro totals

### Progress Tracking
- [ ] Body weight entry
- [ ] Weight history chart
- [ ] Progress photo upload
- [ ] Basic workout consistency view
- [ ] Basic nutrition adherence view

### Coach Connection
- [ ] Coach profile creation
- [ ] Coach search (basic filters)
- [ ] Connection request flow
- [ ] Accept/reject connection
- [ ] Granular data permissions (workouts, nutrition, weight, photos)
- [ ] Remove coach access immediately
- [ ] In-app messaging (text + images)

### Coach Dashboard
- [ ] Coach registration and profile editor
- [ ] Client list
- [ ] View permitted client workouts
- [ ] View permitted client nutrition
- [ ] View weight trends
- [ ] View progress photos (with permission)
- [ ] Send messages
- [ ] Set client macro targets
- [ ] Assign basic workout routines

### Payments (Milestone 6)
- [ ] SyncFit+ subscription ($9.99/month)
- [ ] Coach-set pricing
- [ ] Coaching checkout
- [ ] Recurring coach payments
- [ ] 10% platform commission
- [ ] Cancellation flow

---

## P1 — Should Have (MVP if time allows)

- [ ] Water intake tracking
- [ ] Body measurements (chest, waist, etc.)
- [ ] RPE logging for sets
- [ ] Document sharing in messages
- [ ] Coach reviews/ratings (basic)
- [ ] Email notifications for messages

---

## P2 — Explicitly Excluded from MVP

See `excluded-features.md`

---

## Validation-Driven Adjustments

After 50 interviews, revisit this list:

| Signal | Action |
|--------|--------|
| Nutrition logging ranked #1 pain | Prioritize food search quality |
| Coaches want macro assignment most | Move coach macro targets to P0 |
| Users don't care about photos early | Move photos to P1 |
| $9.99 resistance high | Revisit SyncFit+ value prop before building paywall |

---

## Milestone Mapping

| Milestone | Features |
|-----------|----------|
| M1 Foundation | Account, onboarding, profiles, admin |
| M2 Workout | Exercise DB, logging, routines, history, PRs |
| M3 Nutrition | Food search, meals, macros, custom foods |
| M4 Progress | Weight, photos, charts, adherence |
| M5 Coach | Profiles, search, connections, permissions, messaging |
| M6 Payments | SyncFit+, coach billing, commission |
| M7 QA | Full test pass |
