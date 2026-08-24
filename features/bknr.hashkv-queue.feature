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
