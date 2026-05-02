# Sapphire — Vision

Sapphire is an attempt to make building reliable server software feel simple
again.

Today, even small systems require layers of tools, configuration, protocols, and
operational glue just to function. Sapphire aims to replace that with a model
where you write small pieces of code, connect them together directly, and let
the platform take responsibility for running them reliably.

If everything works as intended, Sapphire should feel less like managing
infrastructure and more like just writing code that does what you want.

---

## The Story: Why Sapphire Exists

This project comes from direct frustration.

I run a small “datacenter at home” where I host storage, automation, media, and
custom applications. The main value I get out of it is home automation and my
media server. My primary focus is reliability because there are some things that
should simply keep working. If a node dies, I should still be able to control my
lights.

Ignoring the layers below Kubernetes, my current stack for controlling my lights
looks roughly like this:

* zigbee2mqtt connects my Zigbee coordinator to MQTT
* mosquitto acts as the MQTT broker
* Home Assistant controls the brightness level of my lights based on schedules,
  manual controls, and other factors
* a custom service controls the color of my lights

This is an overly complicated system with too many moving parts and too many
places for configuration and behavior to hide.

Despite that, controlling my lights is actually one of the most stable and least
complex subsystems in my homelab. A little while ago, one of the NVMe boot
drives in one of my five nodes failed. That node was fried, but I still had full
control over my lights. The only reason I knew anything had happened was an
alert on my phone when I woke up.

So this is not a complaint that everything is broken all the time. The complaint
is that even when things mostly work, the system is still painful to understand,
painful to change, and painful to extend.

I am fine with the home automation running as-is for the moment, but I am very
apprehensive about expanding it. The reasons are familiar:

* the whole system is hard to understand
* changing behavior is far more painful than it should be
* state exists both in code and outside of it
* configuration is scattered and fragile
* infrastructure tools like Kubernetes and Flux slow down iteration
* systems like Ceph regularly fail in ways that are difficult to debug

The end result is this:

> Simple problems require complex systems, and the complexity comes from the
> platform—not the problem.

That is the core issue Sapphire is trying to solve.

---

I also want to acknowledge that I am a bit insane.

I enjoy messing around with BGP, distributed storage, and other such nonsense.
Realistically, I could run TrueNAS with some Docker containers and be perfectly
fine. But this is a problem I find fun and interesting, and I think the fact
that it is fun does not make it less real.

## The Vision: A Better Way to Build Systems

Imagine the same lighting system, but built in Sapphire.

Instead of stitching together multiple protocols, brokers, config files, and
services, I would have a small set of focused services:

* a **Zigbee service** that connects to the coordinator and exposes devices as
  resources
* a **color service** that controls how lights change color
* a **light level service** that controls brightness, schedules, and sleep-aware
  behavior

Each service is small and focused.

They connect directly to each other. No MQTT broker in the middle. No extra glue
layer whose entire purpose is translating one subsystem into another. No chasing
configuration across three different tools.

More importantly, the system should let me model the behavior I actually care
about.

For example, I should be able to:

* expose each light as a resource
* run simple logic per light to cycle through colors at random intervals
* configure behavior quickly without rebuilding a whole deployment workflow
* express higher-level control states like:
  * force the lights on right now
  * have an early night
  * have a late night
* combine event-driven behavior with time-based behavior without turning the
  whole system into spaghetti

If I want to change the behavior, the loop should be simple:

* I change the code or lightweight configuration
* I run it
* the system updates immediately

No Git commit cycle for every tiny change. No reconciliation loop for basic
iteration. No giant JSON blob stuffed into a ConfigMap just to tweak one piece
of behavior.

And when I say:

> I want this service to run in the cluster

Sapphire should make sure that is true.

The exact mechanics of scheduling and fault tolerance are still open questions.
The experience is not. The platform should take responsibility for reliable
execution so that writing reliable clustered software feels direct.

That is the experience Sapphire is trying to create.

---

## Core Principles

Sapphire is still early and many implementation details are unresolved, but a
few principles already feel central.

### Small Services

Everything is a service.

That might include:

* a light controller
* a storage system
* a database
* an authentication system
* an identity service
* a Git server

Each service should do one thing well and compose cleanly with others.

---

### Resources, Handles, and Capabilities

Services interact through **resources**.

A resource might be:

* a light
* a file or block of storage
* a database
* a network endpoint
* another service

You do not primarily interact with the world through paths or ad hoc APIs.
You interact through **handles**.

A handle is a software-level reference to a resource. That resource may be local
or remote. In many cases, that distinction should matter less to the caller than
it does in current systems.

Services should also be able to create new resources and hand out new handles.
That is how abstraction and composition happen.

If you have a handle, you can use the resource according to the capabilities
attached to it.

This should make interactions:

* explicit
* direct
* composable
* easier to reason about

---

### Bindings Instead of Glue

One of the main goals of Sapphire is to make service composition trivial.

Services should receive the resources they depend on through explicit bindings,
in a way that feels more like Cloudflare Workers bindings than traditional
service discovery, SDK wiring, or environment-specific glue.

That means:

* configuration should be lightweight
* swapping one dependency for another should be easy
* inserting a proxy or wrapper should be straightforward
* connecting services should not require everybody to reinvent clients, retries,
  and protocol glue

If I want to add logic between two services, I should be able to write another
service that receives handles of some type, performs logic in the middle, and
exposes handles of the same type.

To use it, consumers should only need to change where their bindings come from.

This is a huge part of the Sapphire vision.

---

### Reliability as a Platform Responsibility

Sapphire is not just about cleaner abstractions. It is about making reliable
behavior the default experience.

The details are still subject to experimentation, but the goal is stable:

* services should run reliably
* failures should be isolated cleanly
* fault tolerance should be built into the model
* distributed systems should not feel like a pile of ad hoc operational hacks

There is still an open question around how much reliability should live in the
runtime versus userland abstractions. Sapphire may end up borrowing heavily from
models like Erlang supervision, or it may take a different path.

What matters is the developer experience on the other side: simple services that
are performant, reliable, and fault tolerant.

---

### Opinionated by Design

Sapphire should be opinionated.

I strongly believe in convention over configuration. The common path should be
obvious, easy, and good. The platform should guide developers toward designs
that are simpler and more reliable.

That does not mean there can be no escape hatches.

It should still be possible to step outside the default conventions when needed,
whether for performance, low-level control, or unusual workloads. But the escape
hatch should feel like an explicit choice, not the normal way to get things
done.

---

### Fast Iteration Is Mandatory

A major reason Sapphire exists at all is that current infrastructure makes small
changes too expensive.

Fast iteration is not a nice bonus. It is one of the core constraints.

The system should make it easy to:

* change behavior quickly
* test ideas quickly
* rewire services quickly
* evolve abstractions through use

If the platform makes iteration slow, it has failed one of its main jobs.

---

## Inspiration

Sapphire is not built in a vacuum. It draws heavily from earlier systems that
solved similar problems.

### Plan 9

Plan 9 treated everything as part of a unified system, where resources could be
accessed in a consistent way.

It showed that:

* simplicity in interfaces leads to simpler systems
* a unified model reduces accidental complexity

Sapphire takes strong inspiration from that, but avoids using filesystem paths
as the primary abstraction. I want software-level references to resources, not a
model where everything ultimately becomes “go look up this path and hope it
means what you think it means.”

---

### Erlang / OTP

Erlang introduced a model for building reliable systems using:

* small processes
* message passing
* supervision and fault tolerance

It showed that:

* reliability can be part of the structure of the system
* failures can be handled cleanly if the model supports it
* highly available software does not need to feel fragile internally

Sapphire aims to carry forward that standard of reliability while exploring a
very different underlying model.

---

### Cloudflare Workers

Cloudflare Workers is an inspiration less because of JavaScript and more because
of developer experience.

I care a lot about:

* simple deployment
* lightweight configuration
* clear bindings to external resources
* immediate iteration

Sapphire is not trying to be Workers, but that style of experience is very much
part of the vision.

---

## What Makes Sapphire Different

Modern systems are usually assembled by layering tools:

* operating system
* containers
* orchestration
* messaging systems
* service frameworks
* external configuration systems

Each layer solves a problem, but each layer also adds more operational surface
area, more indirection, and more places for behavior to hide.

Sapphire tries a different approach:

> Build the right primitives once, and eliminate the need for most of the
> layers.

Instead of adding yet another tool, Sapphire aims to replace large parts of the
stack with a simpler foundation for building server software.

---

## Progressive Adoption and Interoperability

Sapphire is not only useful if it replaces the entire world on day one.

It should be possible to adopt it incrementally.

That means:

* Sapphire services should be able to communicate with existing systems over
  normal network protocols
* existing systems should be able to communicate with Sapphire services
* the runtime should be able to run as a normal process on existing operating
  systems for development, testing, and gradual adoption
* bare-metal deployment may be an eventual target, but it should not be the only
  way Sapphire can be useful

The point is not to create a sealed ecosystem. The point is to build a better
model for server software that can still live in the real world.

---

## What Sapphire Is Not

To be clear, Sapphire is not trying to be:

* a general-purpose operating system
* POSIX-compatible
* a better version of Linux
* another Kubernetes clone
* a wrapper around today’s infrastructure with nicer branding

It is a new approach to building and running server software.

---

## Current Direction (Subject to Change)

Sapphire is still in very early development.

I do not want this document to lock in bad implementation decisions before the
system even exists. The point of this project is to discover the right concrete
shape through experimentation.

The areas that currently feel most important to explore are:

* scheduling, threading, and execution models
* the resource / handle / capability system
* a WebAssembly-based runtime
* a possible custom language designed around Sapphire’s conventions

I feel relatively confident in the direction of resources, handles, and
capabilities as abstractions.

I feel much less certain about exactly how they should manifest:

* Are processes themselves resources?
* Do services dynamically register resources?
* How should handles be created, passed around, or revoked?
* How much should fault tolerance live in the runtime versus userland?
* What should the default execution model feel like?

Those answers should come from implementing real services, running them, and
seeing what feels good or awful in practice.

---

## How It Will Be Built

Sapphire is not being designed all at once.

It is being built through iteration:

1. Identify a real problem
2. Build a simple version
3. Observe what feels wrong
4. Refine or replace the design
5. Repeat

The goal is not to perfectly design the system up front.
The goal is to let the right abstractions emerge from building real things.

That likely means experimenting with services for problems like:

* lighting and home automation
* durable storage
* identity
* Git hosting and collaboration

Over time, Sapphire should earn its abstractions instead of declaring them in
advance.

---

## Long-Term Goal

The long-term goal is simple:

> Running complex systems should feel as simple as writing code.

In practice, Sapphire should make it possible to build and run systems with:

* fast iteration
* clear system behavior
* reliable execution
* simple composition
* lightweight configuration
* strong opinionated defaults

It should eventually be possible to run an entire homelab—or more—on Sapphire.
That includes the sorts of systems I rely on today: storage, identity,
automation, Git, and whatever else the environment needs.

The ambition is large, but the reason is straightforward:

I do not think I should have to give up capability, performance, or reliability
just to get a system that is easier to build and operate.

---

## Closing

Sapphire is an attempt to rethink how server software is built.

It starts from a simple frustration:

> Things that should be easy are not.

And it works toward a simple goal:

> Make them easy again.
