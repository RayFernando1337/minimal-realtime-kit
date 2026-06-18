//  ComponentBuildError.swift
//  T4.2 — why a component builder couldn't produce a view.
//
//  A builder's contract is THROW-on-unusable: a wrong-shaped payload throws at decode, and a
//  decoded-but-empty payload throws one of these. The `ComponentFactory` catches it and
//  returns the mandatory `FallbackComponentVC` (N3), so a malformed payload is always a
//  small, safe card — never a crash. Add one case per new component as you add components.

import Foundation

nonisolated enum ComponentBuildError: Error {
    case emptyNote
    case emptyChoice
    case emptyStatCard
    // Add one case per new component (emptyList, emptyLineChart, …) as you add components.
}
