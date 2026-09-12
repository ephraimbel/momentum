import SwiftUI

/// A small piece of the athlete's plan taking shape, rather than decorative fitness charts.
/// All values are answers or explicit coach choices. The step is captured by value so an outgoing
/// page cannot change its artwork when the shared model advances to the next question.
struct OnboardingScene: View {
    let vm: OnboardingViewModel
    let step: OnboardingViewModel.Step
    @ReducedMotionPreference private var reduceMotion
    @State private var arrived = false

    private var response: Animation? { reduceMotion ? nil : OnboardingStyle.progress }
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
            }, 2, y: 18)
        }.animation(response, value: vm.name)
    }

    private var destination: some View {
        ZStack {
            // Abstract athletics lanes, never represented as a real route or projected mileage.
            ForEach(0..<4) { lane in
                layer(Capsule().strokeBorder(Theme.ink.opacity(lane == 0 ? 0.14 : 0.06), lineWidth: 1)
                    .frame(width: CGFloat(304 - lane * 24), height: CGFloat(128 - lane * 20)), lane,
                      x: lane.isMultiple(of: 2) ? -12 : 12, y: 0)
            }
            VStack(spacing: 6) {
                caption("YOUR NEXT CHAPTER")
                Text(vm.goal == .generalFitness ? "Make it yours." : vm.goal.planLabel)
                    .font(.display(19, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(width: 176, height: 46).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            let selected = [Goal.raceDistance, .endurance, .stayConsistent, .loseFat, .buildMuscle, .getStronger].firstIndex(of: vm.goal)
            layer(symbol(vm.goal.planSystemImage, size: 19, selected: selected != nil)
                .frame(width: 38, height: 38)
                .background(Theme.background, in: Circle())
                .overlay { Circle().strokeBorder(Theme.hairline) }
                .offset(x: CGFloat((selected ?? 0) - 2) * 25, y: 54), 2, x: -18, y: 0)
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
                        .contentTransition(.opacity).lineLimit(1).minimumScaleFactor(0.7)
                    Text("Typical recent week").font(.rounded(10)).foregroundStyle(Theme.inkSecondary)
                }.frame(width: 114, alignment: .leading)
            }, x: -16)
            symbol("arrow.right", size: 14)
            layer(ZStack {
                paper(width: 132, height: 112)
                VStack(alignment: .leading, spacing: 10) {
                    caption("NEXT WEEKS")
                    symbol("calendar.badge.clock", size: 27)
                    Text("Coach planned").font(.rounded(12, weight: .semibold))
                }.frame(width: 108, alignment: .leading)
            }, 1, x: 16)
        }.animation(response, value: vm.weeklyRunVolumeM)
            .animation(response, value: vm.distanceUnitChoice)
    }

    private var protection: some View {
        HStack(spacing: 22) {
            ZStack {
                ForEach(0..<3) { index in
                    let diameter = CGFloat(64 + index * 22)
                    layer(Circle().strokeBorder(Theme.ink.opacity(0.05 + Double(index) * 0.025), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(vm.injuryAreas.isEmpty ? 1 : 1 - CGFloat(index) * 0.06), index, y: 0, tilt: 0)
                }
                layer(symbol("figure.stand", size: 39), 1, y: 8)
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18))
                    .foregroundStyle(vm.injuryAreas.isEmpty ? Theme.inkSecondary : Theme.purple)
                    .padding(8).background(Theme.background, in: Circle()).offset(x: 35, y: 33)
            }.frame(width: 110, height: 116)
            layer(VStack(alignment: .leading, spacing: 9) {
                caption("ROOM FOR RECOVERY")
                Text("Built around you.").font(.display(21, weight: .medium)).lineLimit(2)
                Text(vm.injuryAreas.isEmpty ? "Your history shapes the plan" : "\(vm.injuryAreas.count) areas noted")
                    .font(.rounded(11)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                    .contentTransition(.opacity)
            }.frame(width: 158, alignment: .leading), 2, x: 12)
        }.animation(response, value: vm.injuryAreas)
    }

    private var measurements: some View {
        HStack(spacing: 22) {
            layer(ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Theme.surface).frame(width: 82, height: 114)
                symbol("figure.stand", size: 67)
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
    private func measurementStamp(_ title: String, complete: Bool, index: Int) -> some View {
        layer(HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12)).foregroundStyle(complete ? Theme.purple : Theme.inkTertiary)
                .contentTransition(.opacity)
            Text(title).font(.rounded(11, weight: .medium))
        }
        .frame(width: 91, height: 32)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .scaleEffect(complete ? 1.03 : 1)
        .animation(response, value: complete), index, x: 8, y: 0)
    }

    private var raceBib: some View {
        layer(ZStack {
            paper(width: 265, height: 118, radius: 18)
            VStack(spacing: 9) {
                HStack {
                    Circle().strokeBorder(Theme.hairline).frame(width: 5, height: 5)
                    Spacer(); caption("YOUR START LINE"); Spacer()
                    Circle().strokeBorder(Theme.hairline).frame(width: 5, height: 5)
                }
                HStack(spacing: 12) {
                    symbol("flag.checkered", size: 27, selected: vm.raceDistance != nil)
                    Text(vm.raceDistance?.label ?? "Your race")
                        .font(.display(25, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.opacity)
                }
                Text(vm.hasRace ? vm.raceDate.formatted(.dateTime.month(.abbreviated).day().year()) : "No date needed to begin")
                    .font(.rounded(11)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                    .contentTransition(.opacity)
            }.padding(19).frame(width: 265)
        }, x: 14, y: 18, tilt: -6)
        .animation(response, value: vm.raceDistance)
        .animation(response, value: vm.hasRace)
        .animation(response, value: vm.raceDate)
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
                symbol(equipmentIcon(vm.equipment), size: 46, selected: true).contentTransition(.opacity)
            }, x: -12, tilt: -5)
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

    private var balance: some View {
        HStack(spacing: 20) {
            disciplineCard("figure.run", title: "RUNNING", selected: vm.hybridPriority != .lifting, leading: true)
            symbol("plus", size: 16)
            disciplineCard("dumbbell", title: "STRENGTH", selected: vm.hybridPriority != .running, leading: false)
        }.animation(response, value: vm.hybridPriority)
    }
    private func disciplineCard(_ icon: String, title: String, selected: Bool, leading: Bool) -> some View {
        layer(ZStack {
            paper(width: 115, height: 100)
            VStack(spacing: 12) { symbol(icon, size: 32, selected: selected); caption(title) }
        }.offset(y: selected ? -4 : 5).scaleEffect(selected ? 1 : 0.92), leading ? 0 : 1, x: leading ? -15 : 15, tilt: leading ? -5 : 5)
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
