# Sapphire — Vision

## A Simple Summary

Sapphire is an attempt to make building and running software feel simple again.

Today, even small systems require layers of tools, configuration, and glue just to function. Sapphire aims to replace that with a model where you write small pieces of code, connect them together directly, and the system takes care of running them reliably.

If everything works as intended, Sapphire should feel less like managing infrastructure and more like just writing code that does what you want.

---

## The Story: Why Sapphire Exists

This project comes from direct frustration.

I run a homelab—a small “datacenter at home”—where I host services like storage, automation, and custom applications. On paper, this should be straightforward. In reality, it’s not.

Even something as simple as controlling lights has turned into a complicated system:

* Home Assistant handles brightness
* A custom service handles color
* MQTT is used for communication
* Zigbee2MQTT bridges to physical devices
* Zigbee connects to the lights

Each piece works, but the system as a whole is:

* Hard to understand
* Painful to modify
* Fragile when something changes
* Full of hidden configuration

On top of that, infrastructure is managed with tools like Kubernetes and Flux:

* Every change requires committing to Git
* Iteration is slow
* State exists both in code and outside of it
* Systems like Ceph (for storage) regularly break in ways that are hard to debug

The end result is this:

> Simple problems require complex systems, and the complexity comes from the platform—not the problem.

That’s the core issue Sapphire is trying to solve.

---

## The Vision: A Better Way to Build Systems

Imagine the same lighting system, but built in Sapphire.

Instead of multiple tools and protocols:

* A **Zigbee service** connects to the hardware and exposes lights as resources
* A **color service** controls how lights change color
* A **light level service** controls brightness and schedules

Each service is small and focused.

They connect directly to each other—no MQTT, no glue systems, no extra layers.

If I want to change behavior:

* I change the code
* I run it
* The system updates immediately

No Git commits. No reconciliation loops. No chasing configuration across tools.

The system becomes:

* Easier to understand
* Faster to iterate on
* More reliable

This is the experience Sapphire is trying to create.

---

## What Sapphire Is (Conceptually)

At its core, Sapphire is a platform for running small services that work together.

It is built around a few key ideas:

### Services

Everything is a service:

* A light controller
* A storage system
* A database
* An authentication system

Each service does one thing well.

---

### Resources and Handles

Services interact through **resources**.

A resource is something like:

* A light
* A file
* A database
* Another service

You don’t access resources through paths or APIs.
You access them through **handles**.

If you have a handle, you can use the resource.

This makes interactions:

* Explicit
* Direct
* Easy to reason about

---

### Capabilities

Handles come with **capabilities**, which define what you are allowed to do.

Instead of complex permission systems, the rule is simple:

> If you have the handle, you can use it.

This simplifies how systems are connected and secured.

---

### Composition

Services are composed directly.

If you want to insert logic between two services:

* You write another service
* It receives handles
* It returns new handles

This makes the system naturally composable, without needing external tools or protocols.

---

## Inspiration

Sapphire is not built in a vacuum. It draws heavily from earlier systems that solved similar problems.

### Plan 9

Plan 9 treated everything as part of a unified system, where resources could be accessed in a consistent way.

It showed that:

* Simplicity in interfaces leads to simpler systems
* A unified model reduces complexity

Sapphire takes inspiration from this idea but avoids relying on filesystem paths, which can be fragile and indirect.

---

### Erlang / OTP

Erlang introduced a model for building reliable systems using:

* Small processes
* Message passing
* Supervision and fault tolerance

It showed that:

* Reliability can be built into the structure of the system
* Failures can be handled cleanly if the model supports it

Sapphire aims to bring similar reliability guarantees, while exploring a different underlying model.

---

## What Makes Sapphire Different

Modern systems are built by layering tools:

* Operating system
* Containers
* Orchestration (Kubernetes)
* Messaging systems
* Service frameworks

Each layer adds complexity.

Sapphire tries a different approach:

> Build the right primitives once, and eliminate the need for the layers.

Instead of adding tools, Sapphire replaces them with a simpler foundation.

---

## What Sapphire Is Not

To be clear, Sapphire is not trying to be:

* A general-purpose operating system
* POSIX-compatible
* A better version of Linux
* Another Kubernetes or orchestration tool

It is a new approach to building and running server software.

---

## Current Direction (Subject to Change)

Sapphire is still in very early development.

Some current areas of exploration:

* A WebAssembly-based runtime for running services
* Custom scheduling and execution models
* A capability-based system for managing resources
* A potential custom language designed for the platform

None of these are final.

The system will evolve based on experimentation and real-world usage.

---

## How It Will Be Built

Sapphire is not being designed all at once.

It is being built through iteration:

1. Identify a problem (e.g. lighting system, storage, identity)
2. Build a simple version
3. Observe what feels wrong
4. Refine or replace the design

Over time, the correct abstractions should emerge.

---

## Long-Term Goal

The long-term goal is simple:

> Running complex systems should feel as simple as writing code.

Sapphire should allow:

* Fast iteration
* Clear system behavior
* Reliable execution
* Simple composition of services

It should be possible to run an entire homelab—or more—on Sapphire without needing the layers of tools that exist today.

---

## Closing

Sapphire is an attempt to rethink how server software is built.

It starts from a simple frustration:

> Things that should be easy are not.

And it works toward a simple goal:

> Make them easy again.
