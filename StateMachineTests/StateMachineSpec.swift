import Quick
import Nimble

import SwiftyStateMachine


private struct NumberKeeper {
    var n: Int
}


private enum Number {
    case one, two, three
}

private enum Operation {
    case increment, decrement
}


extension Number: DOTLabelable {
    static var DOTLabelableItems: [Number] {
        return [.one, .two, .three]
    }
}

extension Operation: DOTLabelable {
    static var DOTLabelableItems: [Operation] {
        return [.increment, .decrement]
    }
}


private enum SimpleState { case s1, s2 }
private enum SimpleEvent { case e }

private func createSimpleSchema<T>(_ forward: ((T) -> ())? = nil, backward: ((T) -> ())? = nil) -> StateMachineSchema<SimpleState, SimpleEvent, T> {
    return try! StateMachineSchema(initialState: .s1) { (state, event) in
        switch state {
            case .s1: switch event {
                case .e: return (.s2, { forward?($0) })
            }

            case .s2: switch event {
                case .e: return (.s1, { backward?($0) })
            }
        }
    }
}

private func createSimpleMachine(_ forward: (() -> ())? = nil, backward: (() -> ())? = nil) -> StateMachine<StateMachineSchema<SimpleState, SimpleEvent, Void>> {
    return StateMachine(schema: createSimpleSchema({ _ in forward?() }, backward: { _ in backward?() }), subject: ())
}

private func createMachineWithQueue(_ forward: (() -> ())? = nil, backward: (() -> ())? = nil, queue: DispatchQueue) -> StateMachine<StateMachineSchema<SimpleState, SimpleEvent, Void>> {
    return StateMachine(schema: createSimpleSchema({ _ in forward?() }, backward: { _ in backward?() }), subject: (), queue: queue)
}


private class Subject {
    typealias SchemaType = StateMachineSchema<SimpleState, SimpleEvent, Subject>

    let schema: SchemaType
    lazy var machine: StateMachine<SchemaType> = { 
        StateMachine(schema: self.schema, subject: self)
    }()

    init(schema: SchemaType) {
        self.schema = schema
    }
}


@available(iOS 10.0, *)
class StateMachineSpec: QuickSpec {
    override func spec() {
        describe("State Machine") {
            var keeper: NumberKeeper!
            var keeperMachine: StateMachine<StateMachineSchema<Number, Operation, NumberKeeper>>!

            beforeEach {
                keeper = NumberKeeper(n: 1)

                let schema: StateMachineSchema<Number, Operation, NumberKeeper> = try! StateMachineSchema(initialState: .one) { (state, event) in
                    let decrement: (NumberKeeper) -> () = { _ in keeper.n -= 1 }
                    let increment: (NumberKeeper) -> () = { _ in keeper.n += 1 }

                    switch state {
                        case .one: switch event {
                            case .decrement: return nil
                            case .increment: return (.two, increment)
                        }

                        case .two: switch event {
                            case .decrement: return (.one, decrement)
                            case .increment: return (.three, increment)
                        }

                        case .three: switch event {
                            case .decrement: return (.two, decrement)
                            case .increment: return nil
                        }
                    }
                }

                keeperMachine = StateMachine(schema: schema, subject: keeper)
            }

            it("can be associated with a subject") {
                expect(keeper.n) == 1
                keeperMachine.handleEvent(.increment)
                expect(keeper.n) == 2
            }

            it("doesn't have to be associated with a subject") {
                let machine = createSimpleMachine()

                expect(machine.state) == SimpleState.s1
                machine.handleEvent(.e)
                expect(machine.state) == SimpleState.s2
            }

            it("changes state on correct event") {
                expect(keeperMachine.state) == Number.one
                keeperMachine.handleEvent(.increment)
                expect(keeperMachine.state) == Number.two
            }

            it("doesn't change state on ignored event") {
                expect(keeperMachine.state) == Number.one
                keeperMachine.handleEvent(.decrement)
                expect(keeperMachine.state) == Number.one
            }

            it("executes transition block on transition") {
                var didExecuteBlock = false

                let machine = createSimpleMachine({ didExecuteBlock = true })
                expect(didExecuteBlock) == false

                machine.handleEvent(.e)
                expect(didExecuteBlock) == true
            }

            it("can have transition callback") {
                let machine = createSimpleMachine()

                var callbackWasCalledCorrectly = false
                machine.didTransitionCallback = { (oldState: SimpleState, event: SimpleEvent, newState: SimpleState) in
                    callbackWasCalledCorrectly = oldState == .s1 && event == .e && newState == .s2
                }

                machine.handleEvent(.e)
                expect(callbackWasCalledCorrectly) == true
            }


            it("will call nil transition callback") {
                let trivialSchema = try! StateMachineSchema<SimpleState, SimpleEvent, Void>(initialState: .s1) { (state, event) in
                    if state == .s1 { return (.s2, nil) }
                    else { return nil }
                }
                let machine = StateMachine(schema: trivialSchema, subject: ())

                var callbackWasCalledCorrectly = false
                machine.nilTransitionCallback = { (state: SimpleState, event: SimpleEvent) in
                    callbackWasCalledCorrectly = state == .s2 && event == .e
                }

                machine.handleEvent(.e)
                expect(callbackWasCalledCorrectly) == false
                machine.handleEvent(.e)
                expect(callbackWasCalledCorrectly) == true
            }

            it("can trigger transition from within transition") {
                let subject = Subject(schema: createSimpleSchema({
                    $0.machine.handleEvent(.e)
                }))

                subject.machine.handleEvent(.e)
                expect(subject.machine.state) == SimpleState.s1
            }

            it("doesn't cause machine-subject reference cycles") {
                final class MachineOwner {
                    var machine: StateMachine<StateMachineSchema<SimpleState, SimpleEvent, MachineOwner>>!

                    init() {
                        machine = StateMachine(
                            schema: try! StateMachineSchema(initialState: .s1) { _,_  in nil },
                            subject: self)
                    }
                }

                weak var reference: MachineOwner?
                do { reference = MachineOwner() }
                expect(reference).to(beNil())
            }

            it("uses given dispatch queue in transitions") {
                func currentQueueName() -> String {
                    let name = __dispatch_queue_get_label(nil)
                    return String(cString: name)
                }
                let queue = DispatchQueue(label: "myq")
                let testQueueKey = DispatchSpecificKey<Void>()
                queue.setSpecific(key: testQueueKey, value: ())
                var queueCalled = ""
                let expectation = XCTestExpectation()
                let machine = createMachineWithQueue({
                    dispatchPrecondition(condition: .onQueue(queue))
                    expectation.fulfill()
                    queueCalled = currentQueueName()
                }, queue: queue)
                machine.handleEvent(.e)
                self.wait(for: [expectation], timeout: 1)
                expect(queueCalled).to(equal("myq"))
            }

            it("uses given dispatch queue in transition callback") {
                func currentQueueName() -> String {
                    let name = __dispatch_queue_get_label(nil)
                    return String(cString: name)
                }
                let queue = DispatchQueue(label: "myq")
                let testQueueKey = DispatchSpecificKey<Void>()
                queue.setSpecific(key: testQueueKey, value: ())
                let machine = createMachineWithQueue(queue: queue)
                var queueCalled = ""
                let expectation = XCTestExpectation()
                machine.didTransitionCallback = { _,_,_ in
                    dispatchPrecondition(condition: .onQueue(queue))
                    expectation.fulfill()
                    queueCalled = currentQueueName()
                }
                machine.handleEvent(.e)
                self.wait(for: [expectation], timeout: 1)
                expect(queueCalled).to(equal("myq"))
            }
            

        }

        describe("Graphable State Machine") {

            it("has representation in DOT format") {
                let schema: GraphableStateMachineSchema<Number, Operation, Void> = try! GraphableStateMachineSchema(initialState: .one) { (state, event) in
                    switch state {
                        case .one: switch event {
                            case .decrement: return nil
                            case .increment: return (.two, nil)
                        }

                        case .two: switch event {
                            case .decrement: return (.one, nil)
                            case .increment: return (.three, nil)
                        }

                        case .three: switch event {
                            case .decrement: return (.two, nil)
                            case .increment: return nil
                        }
                    }
                }

                expect(schema.DOTDigraph) == "digraph {\n    graph [rankdir=LR]\n\n    0 [label=\"\", shape=plaintext]\n    0 -> 1 [label=\"START\"]\n\n    1 [label=\"one\"]\n    2 [label=\"two\"]\n    3 [label=\"three\"]\n\n    1 -> 2 [label=\"increment\"]\n    2 -> 3 [label=\"increment\"]\n    2 -> 1 [label=\"decrement\"]\n    3 -> 2 [label=\"decrement\"]\n}"
            }

            it("escapes double quotes in labels") {

                let schema = try! GraphableStateMachineSchema<State, Event, Void>(initialState: .s) { _,_  in
                    (.s, nil)
                }

                expect(schema.DOTDigraph) == "digraph {\n    graph [rankdir=LR]\n\n    0 [label=\"\", shape=plaintext]\n    0 -> 1 [label=\"START\"]\n\n    1 [label=\"An \\\"awesome\\\" state\"]\n\n    1 -> 1 [label=\"An \\\"awesome\\\" event\"]\n}"
            }

        }
    }
}


enum State: DOTLabelable {
    case s
    var DOTLabel: String { return "An \"awesome\" state" }
    static var DOTLabelableItems: [State] { return [.s] }
}

enum Event: DOTLabelable {
    case e
    var DOTLabel: String { return "An \"awesome\" event" }
    static var DOTLabelableItems: [Event] { return [.e] }
}
