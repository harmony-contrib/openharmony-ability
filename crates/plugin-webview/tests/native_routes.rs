//! Production owner/target/controller generation routes, without N-API effects.
#![allow(dead_code)]
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
#[derive(Clone)]
struct NativeWebviewEvent {
    id: String,
    target_id: u32,
    generation: u32,
}
#[path = "../src/native_routes.rs"]
mod native_routes;
use native_routes::NativeEvents;
#[test]
fn owners_targets_and_controller_generations_are_independent() {
    let a = NativeEvents::default();
    let b = NativeEvents::default();
    let hits_a = Arc::new(AtomicUsize::new(0));
    let hits_b = Arc::new(AtomicUsize::new(0));
    let old = a.register("same".into(), 7, {
        let hits = hits_a.clone();
        Arc::new(move |_| {
            hits.fetch_add(1, Ordering::SeqCst);
        })
    });
    let _other = b.register("same".into(), 7, {
        let hits = hits_b.clone();
        Arc::new(move |_| {
            hits.fetch_add(1, Ordering::SeqCst);
        })
    });
    let gen_a = a.prepare("same", 7).unwrap().generation;
    let gen_b = b.prepare("same", 7).unwrap().generation;
    let event = NativeWebviewEvent {
        id: "same".into(),
        target_id: 7,
        generation: gen_a,
    };
    a.dispatch(event.clone());
    assert_eq!(hits_a.load(Ordering::SeqCst), 1);
    assert_eq!(hits_b.load(Ordering::SeqCst), 0);
    b.dispatch(NativeWebviewEvent {
        generation: gen_b,
        ..event.clone()
    });
    assert_eq!(hits_b.load(Ordering::SeqCst), 1);
    a.dispatch(NativeWebviewEvent {
        target_id: 8,
        ..event.clone()
    });
    assert_eq!(hits_a.load(Ordering::SeqCst), 1);
    let generation = a.prepare("same", 7).unwrap().generation;
    assert_ne!(generation, gen_a);
    a.dispatch(event.clone());
    assert_eq!(hits_a.load(Ordering::SeqCst), 1);
    a.dispatch(NativeWebviewEvent {
        generation,
        ..event.clone()
    });
    assert_eq!(hits_a.load(Ordering::SeqCst), 2);
    let new = a.register("same".into(), 9, {
        let hits = hits_a.clone();
        Arc::new(move |_| {
            hits.fetch_add(10, Ordering::SeqCst);
        })
    });
    a.remove("same", &old);
    assert!(a.prepare("same", 7).is_err());
    let generation = a.prepare("same", 9).unwrap().generation;
    a.dispatch(NativeWebviewEvent {
        target_id: 9,
        generation,
        ..event.clone()
    });
    assert_eq!(hits_a.load(Ordering::SeqCst), 12);
    let _ = a.cancel("same", 9, generation - 1);
    a.dispatch(NativeWebviewEvent {
        target_id: 9,
        generation,
        ..event.clone()
    });
    assert_eq!(hits_a.load(Ordering::SeqCst), 22);
    let _ = a.cancel("same", 9, generation);
    a.dispatch(NativeWebviewEvent {
        target_id: 9,
        generation,
        ..event.clone()
    });
    assert_eq!(hits_a.load(Ordering::SeqCst), 22);
    a.invalidate();
    a.dispatch(NativeWebviewEvent {
        target_id: 9,
        generation,
        ..event
    });
    assert_eq!(hits_a.load(Ordering::SeqCst), 22);
    a.remove("same", &new);
}

#[test]
fn controller_identity_does_not_require_an_event_subscriber() {
    let owner = NativeEvents::default();
    let first = owner.prepare("declarations-only", 12).unwrap();
    assert!(owner.attach("declarations-only", 12, first.generation, "tag-first"));
    assert!(owner.is_current("declarations-only", "tag-first"));
    let second = owner.prepare("declarations-only", 12).unwrap();
    assert_eq!(second.previous_tag.as_deref(), Some("tag-first"));
    assert!(!owner.is_current("declarations-only", "tag-first"));
    assert!(!owner.attach("declarations-only", 12, first.generation, "tag-first"));
    assert!(owner.attach("declarations-only", 12, second.generation, "tag-second"));
    assert!(!owner.retire("declarations-only", 12, first.generation, "tag-first"));
    assert!(owner.is_current("declarations-only", "tag-second"));
    assert!(owner.retire("declarations-only", 12, second.generation, "tag-second"));
    assert!(!owner.is_current("declarations-only", "tag-second"));
}
