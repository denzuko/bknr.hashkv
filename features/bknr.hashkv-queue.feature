Feature: Persisted generic queue
  As a caller of bknr.hashkv
  I want entries queued, claimed, acknowledged, and released
  So that a claimed entry is never lost and never claimed twice

  Background:
    Given a fresh bknr.hashkv store

  Scenario: Queuing an entry returns a token id
    When I queue "resize thumbnail" onto the queue
    Then I should get back a token id

  Scenario: Identical payloads still get distinct entries
    When I queue "same payload" onto the queue
    And I queue "same payload" onto the queue again
    Then both queued entries should have different token ids

  Scenario: Claiming returns the oldest unclaimed entry first
    When I queue "first" onto the queue
    And I queue "second" onto the queue
    And a claimant claims the next entry
    Then the claimed payload should be "first"

  Scenario: A claimed entry cannot be claimed again
    When I queue "only entry" onto the queue
    And a claimant claims the next entry
    And another claimant claims the next entry
    Then the second claim should find nothing

  Scenario: Acknowledging a claim removes the entry from the queue
    When I queue "to finish" onto the queue
    And a claimant claims the next entry
    And the claimant acknowledges that claim
    Then a claimant claiming the next entry should find nothing

  Scenario: Releasing a claim makes the entry claimable again
    When I queue "retry me" onto the queue
    And a claimant claims the next entry
    And the claimant releases that claim
    Then a claimant claiming the next entry should find "retry me"

  Scenario: Claiming from an empty queue finds nothing
    Then a claimant claiming the next entry should find nothing

  Scenario: Acknowledging an unknown token id is refused
    When the claimant acknowledges the token id "no-such-token"
    Then the acknowledgement should be refused

  Scenario: Token ids do not depend on the Lisp random state
    When I queue "a" onto the queue from a freshly seeded random state
    And I queue "b" onto the queue from the same freshly seeded random state
    Then both queued entries should have different token ids

  Scenario: Concurrent claimants never claim the same entry twice
    When I queue 50 entries onto the queue
    And 10 claimants drain the queue at once
    Then every entry should have been claimed exactly once

  Scenario: A queued entry survives a store restart
    When I queue "before restart" onto the queue
    And the store is closed and reopened
    Then a claimant claiming the next entry should find "before restart"

  Scenario: A CLOS payload is claimed with its slots after a restart
    When I queue an effect named "poison" with damage 2 onto the queue
    And the store is closed and reopened
    Then a claimant claiming the next entry should find an effect named "poison" with damage 2
