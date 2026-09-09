/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package agent

import "time"

// Package-level constants for hardcoded configuration values.
// These values are no longer configurable via the StorageBasedRemediationConfig CR.

const (
	// PetIntervalMultiple defines the multiple used to calculate the pet interval
	// from the watchdog timeout: pet interval = watchdog timeout / pet interval multiple.
	// The agent discovers the actual watchdog timeout at runtime and derives petInterval
	// using this constant to ensure compatibility with the hardware configuration.
	PetIntervalMultiple = 4

	// MinPetInterval is the minimum allowed pet interval to prevent watchdog starvation
	MinPetInterval = 1 * time.Second

	// MinWatchdogTimeout is the minimum hardware watchdog timeout required to support pet interval with required 3:1 safety margin
	MinWatchdogTimeout = 3 * MinPetInterval

	// WatchdogTimeoutDefault is the default timeout when watchdog timeout discovery fails
	WatchdogTimeoutDefault = 60 * time.Second

	// StaleNodeTimeout is the time after which a node is considered stale and requires remediation check
	StaleNodeTimeout = 1 * time.Hour

	// IoTimeout is the timeout for I/O operations (valid range was 100ms-5min)
	IoTimeout = 2 * time.Second

	// Loglevel is the logging level for the agent logging
	LogLevel = "debug"

	// RebootMethod is the method used to reboot the node
	RebootMethod = "systemctl-reboot"

	// PreflightSentinelPath is the marker file the agent creates only after its pre-flight
	// checks (including the storage write check) pass. The readiness probe waits for this file
	// so the pod cannot become Ready on storage that cannot be written to.
	PreflightSentinelPath = "/var/run/sbr/preflight-ok"
)
