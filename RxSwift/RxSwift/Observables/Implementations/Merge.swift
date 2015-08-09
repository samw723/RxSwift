//
//  Merge.swift
//  Rx
//
//  Created by Krunoslav Zaher on 3/28/15.
//  Copyright (c) 2015 Krunoslav Zaher. All rights reserved.
//

import Foundation

// sequential

class MergeSinkIter<S: ObservableType, O: ObserverType where O.Element == S.E> : ObserverType {
    typealias Element = O.Element
    typealias DisposeKey = Bag<Disposable>.KeyType
    typealias Parent = MergeSink<S, O>
    
    let parent: Parent
    let disposeKey: DisposeKey
    
    init(parent: Parent, disposeKey: DisposeKey) {
        self.parent = parent
        self.disposeKey = disposeKey
    }
    
    func on(event: Event<Element>) {
        switch event {
        case .Next:
            parent.lock.performLocked {
                trySend(parent.observer, event)
            }
        case .Error:
            parent.lock.performLocked {
                trySend(parent.observer, event)
                self.parent.dispose()
            }
        case .Completed:
            let group = parent.mergeState.group
            group.removeDisposable(disposeKey)
            
            self.parent.lock.performLocked {
                let state = parent.mergeState
                
                if state.stopped && state.group.count == 1 {
                    trySendCompleted(parent.observer)
                    self.parent.dispose()
                }
            }
        }
    }
}

class MergeSink<S: ObservableType, O: ObserverType where O.Element == S.E> : Sink<O>, ObserverType {
    typealias Element = S
    typealias Parent = Merge<S>
    
    typealias MergeState = (
        stopped: Bool,
        group: CompositeDisposable,
        sourceSubscription: SingleAssignmentDisposable
    )
    
    let parent: Parent
    
    var lock = NSRecursiveLock()
    
    var mergeState: MergeState = (
        stopped: false,
        group: CompositeDisposable(),
        sourceSubscription: SingleAssignmentDisposable()
    )
    
    init(parent: Parent, observer: O, cancel: Disposable) {
        self.parent = parent
        
        _ = self.mergeState
        
        super.init(observer: observer, cancel: cancel)
    }
    
    func run() -> Disposable {
        let state = self.mergeState
        
        state.group.addDisposable(state.sourceSubscription)
        
        let disposable = self.parent.sources.subscribeSafe(self)
        state.sourceSubscription.disposable = disposable
        
        return state.group
    }
    
    func on(event: Event<Element>) {
        switch event {
        case .Next(let value):
            
            let innerSubscription = SingleAssignmentDisposable()
            let maybeKey = mergeState.group.addDisposable(innerSubscription)
            
            if let key = maybeKey {
                let observer = MergeSinkIter(parent: self, disposeKey: key)
                let disposable = value.subscribeSafe(observer)
                innerSubscription.disposable = disposable
            }
        case .Error(let error):
            lock.performLocked {
                trySendError(observer, error)
                self.dispose()
            }
        case .Completed:
            lock.performLocked {
                let mergeState = self.mergeState
                
                let group = mergeState.group
                
                self.mergeState.stopped = true
                
                if group.count == 1 {
                    trySendCompleted(observer)
                    self.dispose()
                }
                else {
                    mergeState.sourceSubscription.dispose()
                }
            }
        }
    }
}

// concurrent

class MergeConcurrentSinkIter<S: ObservableType, O: ObserverType where S.E == O.Element> : ObserverType {
    typealias Element = O.Element
    typealias DisposeKey = Bag<Disposable>.KeyType
    typealias Parent = MergeConcurrentSink<S, O>
    
    let parent: Parent
    let disposeKey: DisposeKey
    
    init(parent: Parent, disposeKey: DisposeKey) {
        self.parent = parent
        self.disposeKey = disposeKey
    }
    
    func on(event: Event<Element>) {
        switch event {
        case .Next:
            parent.lock.performLocked {
                trySend(parent.observer, event)
            }
        case .Error:
            parent.lock.performLocked {
                trySend(parent.observer, event)
                self.parent.dispose()
            }
        case .Completed:
            parent.lock.performLocked {
                let mergeState = parent.mergeState
                mergeState.group.removeDisposable(disposeKey)
                
                if mergeState.queue.value.count > 0 {
                    let s = mergeState.queue.value.dequeue()
                    self.parent.subscribe(s, group: mergeState.group)
                }
                else {
                    parent.mergeState.activeCount = mergeState.activeCount - 1
                    
                    if mergeState.stopped && parent.mergeState.activeCount == 0 {
                        trySendCompleted(parent.observer)
                        self.parent.dispose()
                    }
                }
            }
        }
    }
}

class MergeConcurrentSink<S: ObservableType, O: ObserverType where S.E == O.Element> : Sink<O>, ObserverType {
    typealias Element = S
    typealias Parent = Merge<S>
    typealias QueueType = Queue<S>
    
    typealias MergeState = (
        stopped: Bool,
        queue: RxMutableBox<QueueType>,
        sourceSubscription: SingleAssignmentDisposable,
        group: CompositeDisposable,
        activeCount: Int
    )
    
    let parent: Parent
    
    var lock = NSRecursiveLock()
    var mergeState: MergeState = (
        stopped: false,
        queue: RxMutableBox(Queue(capacity: 2)),
        sourceSubscription: SingleAssignmentDisposable(),
        group: CompositeDisposable(),
        activeCount: 0
    )
    
    init(parent: Parent, observer: O, cancel: Disposable) {
        self.parent = parent
        
        let state = self.mergeState

        _ = state.group.addDisposable(state.sourceSubscription)
        super.init(observer: observer, cancel: cancel)
    }
    
    func run() -> Disposable {
        let state = self.mergeState

        state.group.addDisposable(state.sourceSubscription)
        
        let disposable = self.parent.sources.subscribeSafe(self)
        state.sourceSubscription.disposable = disposable
        return state.group
    }
    
    func subscribe(innerSource: Element, group: CompositeDisposable) {
        let subscription = SingleAssignmentDisposable()
        
        let key = group.addDisposable(subscription)
        
        if let key = key {
            let observer = MergeConcurrentSinkIter(parent: self, disposeKey: key)
            
            let disposable = innerSource.subscribeSafe(observer)
            subscription.disposable = disposable
        }
    }
    
    func on(event: Event<Element>) {
        switch event {
        case .Next(let value):
            
            let subscribe = lock.calculateLocked { () -> Bool in
                let mergeState = self.mergeState
                if mergeState.activeCount < self.parent.maxConcurrent {
                    self.mergeState.activeCount += 1
                    return true
                }
                else {
                    mergeState.queue.value.enqueue(value)
                    return false
                }
            }
            
            if subscribe {
                self.subscribe(value, group: mergeState.group)
            }
        case .Error(let error):
            lock.performLocked {
                trySendError(observer, error)
                self.dispose()
            }
        case .Completed:
            lock.performLocked {
                let mergeState = self.mergeState
                _ = mergeState.group
                
                if mergeState.activeCount == 0 {
                    trySendCompleted(observer)
                    self.dispose()
                }
                else {
                    mergeState.sourceSubscription.dispose()
                }
                    
                self.mergeState.stopped = true
            }
        }
    }
}

class Merge<S: ObservableType> : Producer<S.E> {
    let sources: Observable<S>
    let maxConcurrent: Int
    
    init(sources: Observable<S>, maxConcurrent: Int) {
        self.sources = sources
        self.maxConcurrent = maxConcurrent
    }
    
    override func run<O: ObserverType where O.Element == S.E>(observer: O, cancel: Disposable, setSink: (Disposable) -> Void) -> Disposable {
        if maxConcurrent > 0 {
            let sink = MergeConcurrentSink(parent: self, observer: observer, cancel: cancel)
            setSink(sink)
            return sink.run()
        }
        else {
            let sink = MergeSink(parent: self, observer: observer, cancel: cancel)
            setSink(sink)
            return sink.run()
        }
    }
}