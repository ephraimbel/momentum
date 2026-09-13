import SwiftUI

/// A small piece of the athlete's plan taking shape, rather than decorative fitness charts.
/// All values are answers or explicit coach choices. The step is captured by value so an outgoing
/// page cannot change its artwork when the shared model advances to the next question.
///
/// Motion pass 2026-09-12: every scene now does three things, in this order. It ASSEMBLES
/// (the finite staggered arrival), it ANSWERS the athlete (one acknowledgement per change, built
/// from `onboardingAcknowledge` and native symbol replaces, each tied to what the question means:
/// a lap for a goal, a ripple for an area to protect, a stamp for a body detail, a beam for the
/// hybrid balance), and its ONE hero object BREATHES (`onboardingHover`) so the page is never a
/// still. Lavender stays the "chosen, right now" colour; nothing here is iridescent.
struct OnboardingScene: View {
    let vm: OnboardingViewModel
    let step: OnboardingViewModel.Step
    @ReducedMotionPreference private var reduceMotion
    @State private var arrived = false

    private var response: Animation? { reduceMotion ? nil : OnboardingStyle.progress }
    /// Values roll between figures; Reduce Motion crossfades them.
    private var roll: ContentTransition { reduceMotion ? .opacity : .numericText() }
    /// One glyph replaces another the way SF Symbols do it; Reduce Motion crossfades.
    private var swap: ContentTransition { reduceMotion ? .opacity : .symbolEffect(.replace) }
    private var name: String { vm.name.split(separator: " ").first.map(String.init) ?? "you" }
    private var initials: String { String(vm.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased() }
    private var unit: DistanceUnit { (vm.distanceUnitChoice.flatMap(DistanceUnit.init(rawValue:)) ?? .auto).resolved() }

    var body: some View {
        GeometryReader { geometry in
            // Decorative art uses a fixed composition; the accessible question and controls
            // below it keep the athlete's Dynamic Type size.
            artwork
                .dynamicTypeSize(.large)
                .frame(width: 320, height: 136)
                .scaleEffect(min(1, min(geometry.size.width / 320, geometry.size.height / 136)))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { arrived = true }
    }

    @ViewBuilder private var artwork: some View {
        switch step {
        case .name, .identity: identity
        case .goal: destination
        case .experience: startingPoint
        case .pace: paces
        case .runVolume: baseline
        case .injuries: protection
        case .metrics: measurements
        case .race, .raceGoalTime: raceBib
        case .days, .preferredDays, .session: calendar
        case .equipment, .strengthSplit: equipment
        case .hybridFocus: balance
        case .intensity: planBrief
        default: destination
        }
    }

    private func paper(width: CGFloat, height: CGFloat, radius: CGFloat = 20) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.background)
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline, lineWidth: 1) }
            .shadow(color: Theme.ink.opacity(0.06), radius: 7, y: 4)
            .frame(width: width, height: height)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.rounded(9, weight: .semibold)).tracking(1.4)
            .foregroundStyle(Theme.inkSecondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func symbol(_ name: String, size: CGFloat = 24, selected: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: size, weight: .light))
            .foregroundStyle(selected ? Theme.purple : Theme.ink)
    }

    private func layer<V: View>(_ content: V, _ index: Int = 0, x: CGFloat = 0, y: CGFloat = 12, tilt: Double = 0) -> some View {
        content.modifier(OnboardingSceneArrival(arrived: arrived, index: index, x: x, y: y, tilt: tilt))
    }

    private var identity: some View {
        ZStack {
            layer(paper(width: 250, height: 106).rotationEffect(.degrees(-5)).offset(x: -7, y: 3), x: -20, tilt: -5)
            layer(paper(width: 258, height: 110).rotationEffect(.degrees(3)).offset(x: 5, y: 2), 1, x: 16, tilt: 5)
            layer(ZStack(alignment: .leading) {
                paper(width: 264, height: 112)
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(Theme.surface).frame(width: 58, height: 66)
                        if initials.isEmpty { symbol("person.crop.circle", size: 30) }
                        else {
                            Text(initials).font(.display(22, weight: .semibold)).foregroundStyle(Theme.purple)
                                .contentTransition(.opacity)
                        }
                    }
                    // The monogram answers every keystroke that changes it, so typing a name
                    // feels like printing it onto the card.
                    .onboardingAcknowledge(trigger: initials, scale: 1.12)
                    VStack(alignment: .leading, spacing: 8) {
                        caption("YOUR TRAINING PLAN")
                        Text(initials.isEmpty ? "Made for you." : "Made for \(name).")
                            .font(.display(21, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(width: 153, alignment: .leading)
                            .contentTransition(.opacity)
                        HStack(spacing: 4) {
                            ForEach(0..<5) { index in
                                Capsule().fill(index == 0 && !initials.isEmpty ? Theme.purple : Theme.hairline)
                                    .frame(width: 22, height: 3)
                            }
                        }
                    }
                }.padding(18)
            }
            // The plan card floats a hair above the two behind it: the stack has depth, and the
            // page has a pulse while the athlete types.
            .onboardingHover(amplitude: 2.5, tilt: 0.8, period: 3.8), 2, y: 18)
        }.animation(response, value: vm.name)
    }

    /// The goals the gallery offers, in its order; `generalFitness` is the unanswered default.
    private static let offeredGoals: [Goal] = [.raceDistance, .endurance, .stayConsistent, .loseFat, .buildMuscle, .getStronger]
    private var goalPicked: Bool { Self.offeredGoals.contains(vm.goal) }

    /// An athletics track, and a lap run around it for every goal the athlete picks. Abstract
    /// lanes, never a real route or a projected distance: the lap is the acknowledgement, the
    /// marker at the finish line carries the goal's own glyph. Each pick re-runs the lap from the
    /// start line (`.id(vm.goal)` gives the lap a fresh view, so it always draws from zero).
    private var destination: some View {
        let outer = CGSize(width: 300, height: 122)
        return ZStack {
            ForEach(0..<3) { lane in
                layer(StadiumLap().stroke(Theme.ink.opacity(lane == 0 ? 0.16 : 0.07), lineWidth: 1)
                    .frame(width: outer.width - CGFloat(lane) * 24, height: outer.height - CGFloat(lane) * 24), lane,
                      x: lane.isMultiple(of: 2) ? -12 : 12, y: 0)
            }
            // The start/finish line, crossing all three lanes at the bottom of the home straight.
            layer(Rectangle().fill(Theme.ink.opacity(0.22)).frame(width: 1.5, height: 26).offset(y: 48), 1, y: 0)
            if goalPicked {
                TrackLapView(size: outer).id(vm.goal)
                    .transition(.opacity)
            }
            VStack(spacing: 6) {
                caption("YOUR NEXT CHAPTER")
                Text(vm.goal == .generalFitness ? "Make it yours." : vm.goal.planLabel)
                    .font(.display(19, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(width: 176, height: 46).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            // The marker waits at the finish line; the glyph swaps to the goal, and the marker
            // lifts once as the lap arrives (the lift is delayed to the lap's own finish).
            layer(symbol(vm.goal.planSystemImage, size: 19, selected: goalPicked)
                .contentTransition(swap)
                .frame(width: 38, height: 38)
                .background(Theme.background, in: Circle())
                .overlay { Circle().strokeBorder(goalPicked ? Theme.purple.opacity(0.5) : Theme.hairline) }
                .onboardingAcknowledge(trigger: vm.goal, scale: 1.18, enabled: goalPicked,
                                       delay: TrackLapView.duration - 0.1)
                .offset(y: outer.height / 2), 2, y: 10)
        }.animation(response, value: vm.goal)
    }

    private var backgroundIndex: Int {
        guard vm.runningBackgroundChosen else { return -1 }
        if vm.returningRunner { return 3 }
        return vm.experience == .new ? 0 : vm.experience == .some ? 1 : 2
    }
    private var backgroundTitle: String {
        switch backgroundIndex {
        case 0: "A gentle beginning"
        case 1: "Build on your routine"
        case 2: "A structured next step"
        case 3: "A fresh starting point"
        default: "Start where you are"
        }
    }
    private var startingPoint: some View {
        VStack(spacing: 14) {
            HStack(spacing: 15) {
                ForEach(Array(["figure.walk", "figure.run", "calendar", "arrow.counterclockwise"].enumerated()), id: \.offset) { index, icon in
                    layer(ZStack {
                        paper(width: 58, height: 60, radius: 18)
                        symbol(icon, size: 25, selected: backgroundIndex == index)
                    }
                    .scaleEffect(backgroundIndex == index ? 1.08 : 0.94)
                    .offset(y: backgroundIndex == index ? -5 : 0)
                    .opacity(backgroundIndex < 0 || backgroundIndex == index ? 1 : 0.5), index, y: 15)
                }
            }
            Text(backgroundTitle).font(.display(17, weight: .medium)).contentTransition(.opacity)
        }.animation(response, value: backgroundIndex)
    }

    /// The plan meeting the athlete where they are: the three paces their anchor implies, as a
    /// card that rolls with every change. Nothing until they set one — the empty card is the
    /// honest picture of a plan with no anchor.
    private var paces: some View {
        let implied = vm.impliedPaces
        let anchored = implied != nil
        return layer(ZStack(alignment: .leading) {
            paper(width: 284, height: 118)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    caption("YOUR TRAINING PACES")
                    Spacer()
                    Text(anchored ? "FROM YOUR ANCHOR" : "NOT SET")
                        .font(.rounded(8, weight: .bold)).tracking(1.0)
                        .foregroundStyle(anchored ? Theme.purple : Theme.inkTertiary)
                        .contentTransition(.opacity)
                }
                paceRow("Easy", implied?.easy, index: 0, lit: anchored)
                paceRow("Steady", implied?.steady, index: 1, lit: anchored)
                paceRow("Repeats", implied?.repeats, index: 2, lit: anchored)
            }
            .frame(width: 246).padding(.horizontal, 19)
        }
        .onboardingHover(amplitude: 2, tilt: 0.5, period: 3.8), y: 16)
        .animation(response, value: implied?.p5k)
    }

    private func paceRow(_ title: String, _ sPerKm: Double?, index: Int, lit: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(lit ? Theme.purple.opacity(0.35 + 0.3 * Double(index)) : Theme.hairline)
                .frame(width: 6, height: 6)
            Text(title).font(.rounded(11, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 58, alignment: .leading)
            Spacer(minLength: 0)
            Text(sPerKm.map { Formatters.pace(secPerKm: $0, unit: unit) } ?? "Not set")
                .font(.display(14, weight: .semibold)).monospacedDigit()
                .foregroundStyle(lit ? Theme.ink : Theme.inkTertiary)
                .contentTransition(reduceMotion ? .opacity : .numericText())
        }
    }

    private func distance(_ meters: Double?) -> String {
        guard let meters else { return "Not sure yet" }
        let value = meters / (unit == .metric ? 1000 : 1609.344)
        return "\(Int(value.rounded())) \(unit == .metric ? "km" : "mi")"
    }
    private var baseline: some View {
        HStack(spacing: 12) {
            layer(ZStack {
                paper(width: 142, height: 112)
                VStack(alignment: .leading, spacing: 10) {
                    caption("RECENT RUNNING")
                    Text(distance(vm.weeklyRunVolumeM)).font(.display(22, weight: .semibold)).monospacedDigit()
                        .contentTransition(roll).lineLimit(1).minimumScaleFactor(0.7)
                    Text(vm.longestRunM.map { "Longest \(distance($0))" } ?? "Typical recent week")
                        .font(.rounded(10)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                        .contentTransition(.opacity).lineLimit(1)
                }.frame(width: 114, alignment: .leading)
            }, x: -16)
            // Every change to the figure pushes the arrow toward the coach's card: the baseline
            // feeds forward, and the page shows it feeding.
            symbol("arrow.right", size: 14)
                .onboardingAcknowledge(trigger: vm.weeklyRunVolumeM, scale: 1, dx: 5)
                .onboardingAcknowledge(trigger: vm.longestRunM, scale: 1, dx: 5)
            layer(ZStack {
                paper(width: 132, height: 112)
                VStack(alignment: .leading, spacing: 10) {
                    caption("NEXT WEEKS")
                    symbol("calendar.badge.clock", size: 27)
                    Text("Coach planned").font(.rounded(12, weight: .semibold))
                }.frame(width: 108, alignment: .leading)
            }, 1, x: 16)
        }.animation(response, value: vm.weeklyRunVolumeM)
            .animation(response, value: vm.longestRunM)
            .animation(response, value: vm.distanceUnitChoice)
    }

    private var protection: some View {
        HStack(spacing: 22) {
            ZStack {
                ForEach(0..<3) { index in
                    let diameter = CGFloat(64 + index * 22)
                    layer(Circle().strokeBorder(Theme.ink.opacity(0.05 + Double(index) * 0.025), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                        // The rings draw in when there is something to protect: the margin
                        // closes around the athlete.
                        .scaleEffect(vm.injuryAreas.isEmpty ? 1 : 1 - CGFloat(index) * 0.06), index, y: 0, tilt: 0)
                }
                // Every area toggled sends one ring out from the figure and lets it fade: the
                // protection being put up. Born visible, expands and dies, resets unseen.
                Circle().strokeBorder(Theme.purple.opacity(0.85), lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .phaseAnimator(RipplePhase.allCases, trigger: vm.injuryAreas) { ring, phase in
                        ring.scaleEffect(reduceMotion ? 1 : phase.scale)
                            .opacity(reduceMotion ? 0 : phase.opacity)
                    } animation: { phase in phase == .spent ? .easeOut(duration: 0.85) : nil }
                layer(symbol("figure.stand", size: 39), 1, y: 8)
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18))
                    .foregroundStyle(vm.injuryAreas.isEmpty ? Theme.inkSecondary : Theme.purple)
                    .padding(8).background(Theme.background, in: Circle())
                    .onboardingAcknowledge(trigger: vm.injuryAreas, scale: 1.22)
                    .offset(x: 35, y: 33)
            }.frame(width: 110, height: 116)
            layer(VStack(alignment: .leading, spacing: 9) {
                caption("ROOM FOR RECOVERY")
                Text("Built around you.").font(.display(21, weight: .medium)).lineLimit(2)
                Text(vm.injuryAreas.isEmpty ? "Your history shapes the plan"
                     : "\(vm.injuryAreas.count) \(vm.injuryAreas.count == 1 ? "area" : "areas") noted")
                    .font(.rounded(11)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                    .contentTransition(roll)
            }.frame(width: 158, alignment: .leading), 2, x: 12)
        }.animation(response, value: vm.injuryAreas)
    }

    /// The ripple's life: rest (unseen) → born small and bright → spent large and gone → rest.
    private enum RipplePhase: CaseIterable {
        case rest, born, spent
        var scale: CGFloat { self == .spent ? 2.05 : 0.9 }
        var opacity: Double { self == .born ? 0.9 : 0 }
    }

    private var measurements: some View {
        HStack(spacing: 22) {
            layer(ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Theme.surface).frame(width: 82, height: 114)
                // The figure follows the answer (the same neutral/female pair the anatomy beats
                // use) and swaps the way SF Symbols swap.
                symbol(vm.sex == .female ? "figure.stand.dress" : "figure.stand", size: 67)
                    .contentTransition(swap)
                    .onboardingAcknowledge(trigger: vm.sex, scale: 1.06, enabled: vm.sex != nil)
                VStack(alignment: .trailing, spacing: 7) {
                    ForEach(0..<9) { index in
                        Capsule().fill(Theme.ink.opacity(0.15)).frame(width: index % 4 == 0 ? 11 : 5, height: 1)
                    }
                }.offset(x: -30)
            }, x: -12)
            VStack(alignment: .leading, spacing: 10) {
                caption("BUILT AROUND YOU")
                HStack(spacing: 8) {
                    measurementStamp("Sex", complete: vm.sex != nil, index: 0)
                    measurementStamp("Age", complete: vm.birthYear != nil, index: 1)
                }
                HStack(spacing: 8) {
                    measurementStamp("Height", complete: vm.heightCm != nil, index: 2)
                    measurementStamp("Weight", complete: vm.bodyMassKg != nil, index: 3)
                }
            }.frame(width: 200, alignment: .leading)
        }
    }
    /// One detail, stamped: the chip presses down as the field is filled (a passport stamp's
    /// landing, not a bounce) and the tick replaces the empty ring natively.
    private func measurementStamp(_ title: String, complete: Bool, index: Int) -> some View {
        layer(HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12)).foregroundStyle(complete ? Theme.purple : Theme.inkTertiary)
                .contentTransition(swap)
            Text(title).font(.rounded(11, weight: .medium))
                .foregroundStyle(complete ? Theme.ink : Theme.inkSecondary)
        }
        .frame(width: 91, height: 32)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(complete ? Theme.purple.opacity(0.35) : .clear) }
        .onboardingAcknowledge(trigger: complete, scale: 1.14, enabled: complete)
        .animation(response, value: complete), index, x: 8, y: 0)
    }

    /// The bib's big figure and its unit: the numbers runners actually say. 5K, 10K and 50K keep
    /// their K in every locale; the half and the full become 13.1 / 26.2 (mi) or 21.1 / 42.2 (km).
    private var bibFigure: (number: String, unit: String)? {
        guard let d = vm.raceDistance else { return nil }
        let metric = unit == .metric
        switch d {
        case .fiveK: return ("5", "K")
        case .tenK: return ("10", "K")
        case .half: return metric ? ("21.1", "KM") : ("13.1", "MI")
        case .marathon: return metric ? ("42.2", "KM") : ("26.2", "MI")
        case .fiftyK: return ("50", "K")
        }
    }

    /// A race bib, pinned at its top corners. The distance is the bib number and rolls when the
    /// athlete changes it; their name is printed on it; the date stamps on when they add one.
    /// It hangs, so it sways: the one breathing object on this page.
    private var raceBib: some View {
        layer(ZStack {
            paper(width: 265, height: 118, radius: 18)
            // Pin holes in all four corners.
            VStack {
                HStack { pinHole; Spacer(); pinHole }
                Spacer()
                HStack { pinHole; Spacer(); pinHole }
            }.padding(9).frame(width: 265, height: 118)
            VStack(spacing: 4) {
                caption(vm.plannedRaceName?.uppercased() ?? "YOUR START LINE")
                    .frame(width: 200).contentTransition(.opacity)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    symbol("flag.checkered", size: 22, selected: vm.raceDistance != nil)
                        .offset(y: -1)
                        .onboardingAcknowledge(trigger: vm.raceDistance, scale: 1.18, enabled: vm.raceDistance != nil)
                    if let figure = bibFigure {
                        Text(figure.number).font(.display(34, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.ink).contentTransition(roll)
                        Text(figure.unit).font(.display(15, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                            .contentTransition(.opacity)
                    } else {
                        Text("Your race").font(.display(25, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(height: 40)
                HStack(spacing: 6) {
                    Text(vm.name.isEmpty ? "ATHLETE" : vm.name.split(separator: " ").first.map { String($0).uppercased() } ?? "ATHLETE")
                        .font(.rounded(10, weight: .bold)).tracking(1.2).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("·").foregroundStyle(Theme.inkTertiary)
                    Text(vm.hasRace ? vm.raceDate.formatted(.dateTime.month(.abbreviated).day().year()) : "No date needed to begin")
                        .font(.rounded(11, weight: vm.hasRace ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(vm.hasRace ? Theme.purple : Theme.inkSecondary)
                        .contentTransition(.opacity)
                        // The date lands like a stamp when a race day is switched on.
                        .onboardingAcknowledge(trigger: vm.hasRace, scale: 1.16, enabled: vm.hasRace)
                }
            }.padding(.horizontal, 19).frame(width: 265)
        }
        .onboardingHover(amplitude: 0, tilt: 1.3, period: 3.6, anchor: .top), x: 14, y: 18, tilt: -6)
        .animation(response, value: vm.raceDistance)
        .animation(response, value: vm.hasRace)
        .animation(response, value: vm.raceDate)
        .animation(response, value: vm.plannedRaceName)
    }

    private var pinHole: some View {
        Circle().strokeBorder(Theme.ink.opacity(0.14), lineWidth: 1).frame(width: 6, height: 6)
    }

    private var calendar: some View {
        VStack(spacing: 15) {
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { day in
                    let chosen = vm.preferredDays.contains(day)
                    layer(VStack(spacing: 9) {
                        Text(Calendar.current.veryShortWeekdaySymbols[day - 1]).font(.rounded(11, weight: .semibold))
                        Image(systemName: chosen ? "checkmark" : "minus").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(chosen ? Theme.purple : Theme.ink.opacity(0.18))
                    }
                    .frame(width: 36, height: 55)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? Theme.purple.opacity(0.4) : Theme.hairline) }
                    .offset(y: chosen ? -5 : 0), day - 1, y: 10)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(vm.daysPerWeek)").font(.display(25, weight: .semibold)).monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                Text("days. We'll arrange the sessions.").font(.rounded(12)).foregroundStyle(Theme.inkSecondary)
            }
        }.animation(response, value: vm.daysPerWeek)
            .animation(response, value: vm.preferredDays)
    }

    private var equipmentName: String {
        switch vm.equipment {
        case .fullGym: "Full gym"
        case .dumbbellsOnly: "Dumbbells only"
        case .homeMinimal: "Home minimal"
        case .bodyweight: "Bodyweight"
        }
    }
    private func equipmentIcon(_ equipment: Equipment) -> String {
        switch equipment {
        case .fullGym: "figure.strengthtraining.traditional"
        case .dumbbellsOnly: "dumbbell"
        case .homeMinimal: "house"
        case .bodyweight: "figure.core.training"
        }
    }
    private var equipment: some View {
        HStack(spacing: 18) {
            layer(ZStack {
                paper(width: 108, height: 108, radius: 28)
                symbol(equipmentIcon(vm.equipment), size: 46, selected: true)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
            }
            .onboardingAcknowledge(trigger: vm.equipment, scale: 1.05)
            .onboardingHover(amplitude: 2, tilt: 0.6, period: 3.6), x: -12, tilt: -5)
            layer(VStack(alignment: .leading, spacing: 10) {
                caption("YOUR STRENGTH SETUP")
                Text(equipmentName).font(.display(20, weight: .semibold)).lineLimit(1)
                    .minimumScaleFactor(0.7).contentTransition(.opacity)
                HStack(spacing: 10) {
                    ForEach(Equipment.allCases, id: \.self) { item in
                        symbol(equipmentIcon(item), size: 15, selected: vm.equipment == item)
                            .opacity(vm.equipment == item ? 1 : 0.3)
                            .scaleEffect(vm.equipment == item ? 1.12 : 1)
                    }
                }.frame(height: 24)
            }.frame(width: 168, alignment: .leading), 1, x: 12)
        }.animation(response, value: vm.equipment)
    }

    /// How far the beam leans toward running. Every option is a running plan, so the beam never
    /// tips toward strength: it settles level at most ("near-even split").
    private var beamTilt: Double {
        switch vm.hybridPriority {
        case .running: -6
        case .balanced: -3
        case .lifting: 0
        }
    }
    /// A balance: the two disciplines on a beam over a fulcrum. Picking an emphasis tips the
    /// beam, and the cards ride it (dropping on the heavy side, rising on the light one) while
    /// staying upright, so the question's answer is a physical thing the page does.
    private var balance: some View {
        // The cards sit ±halfSpan from the fulcrum; the beam's tilt moves their ends by sin(tilt).
        let halfSpan: CGFloat = 78
        let drop = CGFloat(sin(beamTilt * .pi / 180)) * halfSpan
        return VStack(spacing: 0) {
            HStack(spacing: 40) {
                disciplineCard("figure.run", title: "RUNNING", selected: vm.hybridPriority != .lifting, leading: true)
                    .offset(y: -drop)
                disciplineCard("dumbbell", title: "STRENGTH", selected: vm.hybridPriority != .running, leading: false)
                    .offset(y: drop)
            }
            ZStack {
                Capsule().fill(Theme.ink.opacity(0.22)).frame(width: halfSpan * 2 + 60, height: 2)
                    .rotationEffect(.degrees(beamTilt))
                    .offset(y: -3)
                Image(systemName: "triangle.fill").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.35)).offset(y: 5)
            }
            .frame(height: 12)
            .modifier(OnboardingSceneArrival(arrived: arrived, index: 2, x: 0, y: 6, tilt: 0))
        }.animation(response, value: vm.hybridPriority)
    }
    private func disciplineCard(_ icon: String, title: String, selected: Bool, leading: Bool) -> some View {
        layer(ZStack {
            paper(width: 108, height: 88)
            VStack(spacing: 10) {
                symbol(icon, size: 30, selected: selected)
                    .onboardingAcknowledge(trigger: vm.hybridPriority, scale: 1.14, enabled: selected)
                caption(title)
            }
        }.scaleEffect(selected ? 1 : 0.92), leading ? 0 : 1, x: leading ? -15 : 15, tilt: leading ? -5 : 5)
    }

    private var planBrief: some View {
        ZStack {
            layer(paper(width: 267, height: 106).rotationEffect(.degrees(4)).offset(x: 7, y: 4), x: 18, tilt: 5)
            layer(ZStack(alignment: .leading) {
                paper(width: 279, height: 118)
                HStack(spacing: 17) {
                    VStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.purple).frame(width: 25, height: 25)
                                .background(Theme.purple.opacity(0.08), in: Circle())
                                .modifier(OnboardingSceneArrival(arrived: arrived, index: index + 1, x: -8, y: 0, tilt: 0))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        caption("YOUR PLAN BRIEF")
                        Text(vm.goal == .raceDistance ? (vm.raceDistance?.label ?? "Your race") : vm.goal.planLabel)
                            .font(.display(22, weight: .semibold)).lineLimit(2)
                            .minimumScaleFactor(0.7).contentTransition(.opacity)
                        Text("\(vm.intensity.label) · \(vm.daysPerWeek) days")
                            .font(.rounded(10)).monospacedDigit().foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    }.frame(width: 200, alignment: .leading)
                }.padding(17)
            }, 1, y: 15)
        }.animation(response, value: vm.intensity)
    }
}

/// A stadium track: one closed lap starting at the bottom of the home straight (the start/finish
/// line) and running anticlockwise, the way a track is run. `.trim` draws a partial lap.
struct StadiumLap: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The runner's head on a partial lap: a dot at the END of the trimmed track path (a trimmed
/// path's `currentPoint` is its end, which is exactly the point being drawn).
struct LapHead: Shape {
    var progress: CGFloat
    var radius: CGFloat = 4
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let lap = StadiumLap().path(in: rect).trimmedPath(from: 0, to: max(progress, 0.0005))
        guard let c = lap.currentPoint else { return Path() }
        return Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// One lap of the outer lane, drawn from the start line the moment the view exists: lavender,
/// because it is the athlete's pick happening right now; a soft head leading the line, which
/// settles at the finish. Reduce Motion shows the lap complete.
struct TrackLapView: View {
    let size: CGSize
    static let duration = 1.3
    @State private var progress: CGFloat = 0
    /// Once the lap is run it settles to a trace: lavender marks the pick happening, and a
    /// full lavender ring left behind would be decoration. The marker keeps the colour.
    @State private var settled = false
    @ReducedMotionPreference private var reduceMotion

    var body: some View {
        ZStack {
            StadiumLap().trim(from: 0, to: progress)
                .stroke(Theme.purple, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .opacity(settled ? 0.28 : 1)
            LapHead(progress: progress, radius: 4.5).fill(Theme.purple)
                .shadow(color: Theme.purple.opacity(0.55), radius: 5)
                .opacity(progress > 0 && !settled ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            guard reduceMotion else {
                withAnimation(Motion.pen(Self.duration).delay(0.05)) { progress = 1 }
                withAnimation(.easeOut(duration: 0.7).delay(Self.duration + 0.35)) { settled = true }
                return
            }
            progress = 1
            settled = true
        }
    }
}

/// A finite, staggered assembly. Only transforms/opacity animate; no timers, perpetual redraws,
/// layout animation or motion sensors. Reduce Motion renders the completed composition immediately.
private struct OnboardingSceneArrival: ViewModifier {
    let arrived: Bool
    let index: Int
    let x: CGFloat
    let y: CGFloat
    let tilt: Double
    @ReducedMotionPreference private var reduceMotion
    private var settled: Bool { arrived || reduceMotion }

    func body(content: Content) -> some View {
        content
            .opacity(settled ? 1 : 0.35)
            .offset(x: settled ? 0 : x, y: settled ? 0 : y)
            .rotationEffect(.degrees(settled ? 0 : tilt))
            .animation(reduceMotion ? nil : .spring(response: 0.62, dampingFraction: 0.86).delay(Double(min(index, 5)) * 0.045), value: arrived)
    }
}
