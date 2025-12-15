import core.thread;
import core.time;
import std.math;
import utils;

/**
 * ScheduledEvent - Event with Fiber and execution time (in microseconds)
 * Intrusive node in circular doubly-linked list of scheduled events
 */
struct ScheduledEvent
{
	Fiber fiber;
	long executeTimeUs;  // Microseconds since epoch (from TimeUtils)
	EventScheduler* scheduler;  // Pointer to owning scheduler for cancellation
	ScheduledEvent* prev;  // Previous node in circular list
	ScheduledEvent* next;  // Next node in circular list
	
	/**
	 * Cancel this scheduled event (O(1) removal via unlink)
	 */
	void cancel()
	{
		if (scheduler)
			scheduler.removeEvent(&this);
	}
}

/**
 * EventScheduler - Timeline-based event system using Fibers with Circular Linked List
 * Events are scheduled with a delay or absolute time and executed deterministically
 * when their time arrives. Single-threaded, microsecond precision.
 * 
 * Architecture: Intrusive circular doubly-linked list. Events are executed
 * when their scheduled time arrives; those scheduled during execution are
 * processed in subsequent `processReady()` iterations. Removal via O(1) unlink.
 */
class EventScheduler
{
	private ScheduledEvent* head;  // Head of circular list (null if empty)
	private ScheduledEvent* current;  // Current position during processReady()
	
	this()
	{
		head = null;
		current = null;
	}
	
	/**
	 * Schedule an event to execute after a delay (microseconds)
	 * Returns a pointer to the event in the pool for optional cancellation
	 */
	ScheduledEvent* scheduleEvent(long delayUs, void delegate() action)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleAtTime(executeTimeUs, action);
	}
	
	/**
	 * Schedule an event to execute at an absolute time (microseconds)
	 * Returns a pointer to the event in the pool for optional cancellation
	 */
	ScheduledEvent* scheduleAtTime(long executeTimeUs, void delegate() action)
	{
		// Create fiber that runs action directly
		Fiber fiber = new Fiber(() {
			action();
		});
		
		// Allocate event on heap
		ScheduledEvent* event = new ScheduledEvent();
		event.fiber = fiber;
		event.executeTimeUs = executeTimeUs;
		event.scheduler = cast(EventScheduler*)this;
		event.prev = null;
		event.next = null;
		
		// Insert into circular list
		insertNode(event);
		
		return event;
	}
	
	/**
	 * Insert a node into the circular list (add at end, before head)
	 */
	private void insertNode(ScheduledEvent* node)
	{
		if (head == null)
		{
			// First node: point to itself
			head = node;
			node.prev = node;
			node.next = node;
		}
		else
		{
			// Insert before head (at end of list)
			node.next = head;
			node.prev = head.prev;
			head.prev.next = node;
			head.prev = node;
		}
	}
	
	/**
	 * Remove a node from the circular list via unlink (O(1) operation)
	 * Adjusts prev/next pointers and destroys the node.
	 */
	package void removeEvent(ScheduledEvent* node)
	{
		if (node == null || head == null)
			return;
		
		// If only one node, it's the head
		if (node.next == node)
		{
			head = null;
			current = null;
		}
		else
		{
			// Unlink the node
			node.prev.next = node.next;
			node.next.prev = node.prev;
			
			// If removing current node, advance to next
			if (current == node)
				current = node.next;
			
			// If removing head, update head
			if (head == node)
				head = node.next;
		}
		
		destroy(node);
	}
	
	/**
	 * Process all ready events in the circular list
	 * Traverses the list exactly once, executing events when due.
	 */
	void processReady()
	{
		if (head == null)
			return;
		
		long currentTimeUs = TimeUtils.currTimeUs();
		
		// Start or resume traversal from head
		if (current == null)
			current = head;
		
		ScheduledEvent* startNode = current;
		bool firstIteration = true;
		
		// Sweep through list exactly once
		do
		{
			ScheduledEvent* e = current;
			ScheduledEvent* nextNode = e.next;  // Save next before potential removal
			
			// Check if event is due
			if (e.executeTimeUs <= currentTimeUs)
			{
				// Execute the event
				e.fiber.call();
				
				// Remove completed event from list
				removeEvent(e);
				
				// If list is now empty, exit
				if (head == null)
				{
					current = null;
					break;
				}
				
				// Continue from next node (which was already saved)
				current = nextNode;
			}
			else
			{
				// Advance to next node
				current = nextNode;
			}
			
			firstIteration = false;
			
		} while (current != startNode && head != null);
		
		// Reset current if we've completed a full sweep
		if (current == startNode && !firstIteration)
			current = null;
	}
	
	/**
	 * Process all ready events by repeatedly calling processReady()
	 * Runs while the list has events.
	 * Handles event chaining: events scheduled during execution are processed
	 * as traversal continues through the list.
	 */
	void processEvents()
	{
		while (head != null)
		{
			processReady();
		}
	}
	
	/**
	 * Check if there are any pending events
	 */
	bool hasEvents()
	{
		return head != null;
	}
	
	/**
	 * Get next event's execution time (microseconds)
	 */
	long nextEventTimeUs()
	{
		if (head == null)
			return long.max;
		
		long nextTime = long.max;
		ScheduledEvent* node = head;
		
		do
		{
			if (node.executeTimeUs < nextTime)
				nextTime = node.executeTimeUs;
			node = node.next;
		} while (node != head);
		
		return nextTime;
	}
	
	/**
	 * Clear all events
	 */
	void clear()
	{
		while (head != null)
		{
			ScheduledEvent* next = head.next;
			removeEvent(head);
			// removeEvent updates head, so we continue with what's left
			// No comparison needed; the while condition handles empty list
		}
		// head is already null from removeEvent, but be explicit
		head = null;
		current = null;
	}
}