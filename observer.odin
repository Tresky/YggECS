package observer

import "core:fmt"
import "core:mem"

// Define the Observable type
Observable :: struct {
    observers: [dynamic]^Observer,
}

// Define the Observer type
Observer :: struct {
    update: proc(data: any),
}

// Initialize a new Observable
new_observable :: proc() -> ^Observable {
    s := new(Observable)
    s.observers = make([dynamic]^Observer)
    return s
}

// Add an observer to the observable
attach :: proc(s: ^Observable, o: ^Observer) {
    append(&s.observers, o)
}

// Remove an observer from the observable
detach :: proc(s: ^Observable, o: ^Observer) {
    for i := 0; i < len(s.observers); i += 1 {
        if s.observers[i] == o {
            ordered_remove(&s.observers, i)
            break
        }
    }
}

// Notify all observers of a change
notify :: proc(s: ^Observable, data: any) {
    for observer in s.observers {
        observer.update(data)
    }
}

// Create a new observer
new_observer :: proc(update_proc: proc(data: any)) -> ^Observer {
    o := new(Observer)
    o.update = update_proc
    return o
}

// Example usage
main :: proc() {
    observable := new_observable()
    defer {
        for observer in observable.observers {
            free(observer)
        }
        delete(observable.observers)
        free(observable)
    }

    observer1 := new_observer(proc(data: any) {
        fmt.printf("Observer 1 received: %v\n", data)
    })
    observer2 := new_observer(proc(data: any) {
        fmt.printf("Observer 2 received: %v\n", data)
    })

    attach(observable, observer1)
    attach(observable, observer2)

    notify(observable, "Hello, observers!")

    detach(observable, observer1)

    notify(observable, "Observer 1 has been detached")
}
