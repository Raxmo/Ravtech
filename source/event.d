import core.thread;
import core.time;
import std.stdio;
import utils;

/**
 * EventType - Event listener organization and propagation strategy
 * 
 * Pool: Flat, unordered listeners. All fired immediately.
 * Bubble: Hierarchical listeners, child → parent propagation.
 * Trickle: Hierarchical listeners, parent → child propagation.
 */
enum EventType
{
	Pool,       // Flat listener collection
	Bubble,     // Hierarchical, child → parent
	Trickle     // Hierarchical, parent → child
}

/**
 * ITrigger - Type-erased trigger interface
 * 
 * All triggers implement this interface to allow type-agnostic scheduling.
 * The scheduler works entirely with ITrigger references.
 */
interface ITrigger
{
	/// Execute the trigger, notifying its linked event with stored payload
	void notify();
}

/**
 * ListenerContainer - Abstract interface for listener storage and propagation
 * Generic over payload type T
 */
interface ListenerContainer(T)
{
	alias ListenerDelegate = void delegate(Event!T event);
	
	void addListener(ListenerDelegate listener);
	void removeListener(ListenerDelegate listener);
	void fire(Event!T event);
}

/**
 * HierarchicalListener - Node in the listener tree
 */
final class HierarchicalListener(T)
{
	alias ListenerDelegate = void delegate(Event!T event);
	
	ListenerDelegate callback;
	HierarchicalListener!T parent;
	HierarchicalListener!T[] children;
	
	this(ListenerDelegate cb)
	{
		this.callback = cb;
		this.parent = null;
	}
	
	void addChild(HierarchicalListener!T child)
	{
		child.parent = this;
		children ~= child;
	}
	
	void removeChild(HierarchicalListener!T child)
	{
		foreach (i, c; children)
		{
			if (c == child)
			{
				children = children[0 .. i] ~ children[i + 1 .. $];
				return;
			}
		}
	}
}

/**
 * HierarchicalContainer - Listener tree with configurable propagation
 */
final class HierarchicalContainer(T) : ListenerContainer!T
{
	alias ListenerDelegate = void delegate(Event!T event);
	
	private EventType propagationType;
	private HierarchicalListener!T[] roots;
	this(EventType propType)
	{
		this.propagationType = propType;
	}
	
	void addListener(ListenerDelegate listener)
	{
		HierarchicalListener!T node = new HierarchicalListener!T(listener);
		roots ~= node;
	}
	
	void removeListener(ListenerDelegate listener)
	{
		foreach (i, root; roots)
		{
			if (root.callback == listener)
			{
				roots = roots[0 .. i] ~ roots[i + 1 .. $];
				return;
			}
		}
	}
	
	void fire(Event!T event)
	{
		final switch (propagationType)
		{
			case EventType.Pool:
				// Pool: Fire roots only, no propagation to children
				foreach (root; roots)
				{
					if (root.callback)
						root.callback(event);
				}
				break;
			case EventType.Trickle:
				// Trickle: Parent → Child propagation
				foreach (root; roots)
					trickleDown(root, event);
				break;
			case EventType.Bubble:
				// Bubble: Child → Parent propagation
				foreach (root; roots)
					bubbleUp(root, event);
				break;
		}
	}
	
	private void trickleDown(HierarchicalListener!T node, Event!T event)
	{
		if (node.callback)
			node.callback(event);
		
		if (event.consumed)
			return;
		
		foreach (child; node.children)
			trickleDown(child, event);
	}

	private void bubbleUp(HierarchicalListener!T node, Event!T event)
	{
		foreach (child; node.children)
			bubbleUp(child, event);
		
		if (event.consumed)
			return;
		
		if (node.callback)
			node.callback(event);	
	}
}

/**
 * Event - Reusable, stateful event with typed payload and listeners
 * 
 * Fires listeners using a container that handles storage and propagation.
 * Payload is set by Trigger before fire() and holds type-safe data for listeners.
 * T: Payload type (use void for no payload)
 */
class Event(T)
{
	protected string name;
	protected ListenerContainer!T container;
	protected T payload;
	protected bool consumed = false;
	
	this(string name, EventType type)
	{
		this.name = name;
		this.container = new HierarchicalContainer!T(type);
	}
	
	/**
	 * Add a listener callback
	 */
	void addListener(void delegate(Event!T) listener)
	{
		container.addListener(listener);
	}
	
	/**
	 * Remove a listener callback
	 */
	void removeListener(void delegate(Event!T) listener)
	{
		container.removeListener(listener);
	}
	
	/**
	 * Fire this event, invoking all listeners via container
	 */
	void fire()
	{
		container.fire(this);
	}
	
	/**
	 * Notify listeners with a specific payload
	 * Called by triggers to deliver the payload
	 */
	void notifyWithPayload(T payload)
	{
		this.payload = payload;
		this.consumed = false;  // Reset consumption flag
		fire();
	}
	
	/**
	 * Get payload (called by listeners)
	 */
	T getPayload() const
	{
		return payload;
	}
	
	/**
	 * Mark event as consumed to stop propagation
	 */
	void consume()
	{
		consumed = true;
	}
	
	/**
	 * Check if event was consumed
	 */
	bool isConsumed() const
	{
		return consumed;
	}
	
	@property string getName() const { return name; }
}

/**
 * Trigger - Typed trigger implementing ITrigger
 * 
 * Carries an event and payload, implements type-erased notify() interface.
 * Can be executed immediately or scheduled with TriggerScheduler.
 * T: Payload type passed to listeners
 */
class Trigger(T) : ITrigger
{
	Event!T targetEvent;
	T payload;
	
	this(Event!T event, T data)
	{
		this.targetEvent = event;
		this.payload = data;
	}
	
	/**
	 * Notify the linked event with this trigger's payload
	 * Implements ITrigger interface for type-agnostic scheduling
	 */
	void notify()
	{
		targetEvent.notifyWithPayload(payload);
	}
	
	@property Event!T getEvent() { return targetEvent; }
}



/**
 * ScheduledTrigger - Instance of a trigger scheduled for execution
 * 
 * Non-templated node storing ITrigger reference.
 * Intrusive node in circular doubly-linked list.
 * Works with all trigger types regardless of payload.
 */
struct ScheduledTrigger
{
	ITrigger trigger;
	long executeTimeUs;
	ScheduledTrigger* prev;
	ScheduledTrigger* next;
	
	void cancel()
	{
		TriggerScheduler.removeScheduledTrigger(&this);
	}
}

/**
 * TriggerScheduler - Global timeline managing all scheduled triggers
 * 
 * Single-threaded, microsecond precision event execution.
 * Uses circular doubly-linked list for O(1) removal and efficient traversal.
 * Type-agnostic: works with all trigger types through ITrigger interface.
 */
static class TriggerScheduler
{
	private static ScheduledTrigger* head;
	private static ScheduledTrigger* current;
	
	/**
	 * Schedule a trigger for execution at an absolute time (sorted insertion)
	 */
	static ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		insertNodeSorted(scheduled);
		
		return scheduled;
	}
	
	/**
	 * Schedule a trigger with a delay from now
	 */
	static ScheduledTrigger* scheduleTrigger(ITrigger trigger, long delayUs, bool isDelay)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleTrigger(trigger, executeTimeUs);
	}
	
	/**
	 * Remove a scheduled trigger from the timeline
	 */
	static void removeScheduledTrigger(ScheduledTrigger* node)
	{
		if (node == null || head == null)
			return;
		
		if (node.next == node)
		{
			// Only node in list
			head = null;
			current = null;
		}
		else
		{
			// Unlink the node
			node.prev.next = node.next;
			node.next.prev = node.prev;
			
			if (current == node)
				current = node.next;
			
			if (head == node)
				head = node.next;
		}
		
		destroy(node);
	}
	
	/**
	 * Insert a node into sorted position (ascending by executeTimeUs)
	 * Walks backwards from tail for O(1) insertion in typical use case
	 */
	private static void insertNodeSorted(ScheduledTrigger* node)
	{
		if (head == null)
		{
			// First node
			head = node;
			node.prev = node;
			node.next = node;
			current = null;
			return;
		}
		
		// Walk backwards from tail, comparing with new node's executeTime
		ScheduledTrigger* pos = head.prev;  // Start at tail
		
		// Find insertion point: first node with executeTimeUs <= new node's time
		while (pos != head && pos.executeTimeUs > node.executeTimeUs)
		{
			pos = pos.prev;
		}
		
		// Now pos is either head (new node should be first) or a node with executeTimeUs <= new node's time
		if (pos == head && head.executeTimeUs > node.executeTimeUs)
		{
			// New node is earliest, insert before head
			node.next = head;
			node.prev = head.prev;
			head.prev.next = node;
			head.prev = node;
			head = node;  // New head
		}
		else
		{
			// Insert after pos
			node.next = pos.next;
			node.prev = pos;
			pos.next.prev = node;
			pos.next = node;
		}
	}
	
	/**
	 * Process next ready trigger if available
	 * Since list is sorted, head is always the next trigger to execute
	 */
	static void processReady()
	{
		if (head == null)
			return;
		
		long currentTimeUs = TimeUtils.currTimeUs();
		
		if (head.executeTimeUs <= currentTimeUs)
		{
			// Head is ready, execute and remove
			head.trigger.notify();
			removeScheduledTrigger(head);
		}
	}
	
	/**
	 * Process all pending triggers until list is empty
	 */
	static void processAll()
	{
		while (head != null)
		{
			processReady();
		}
	}
	
	/**
	 * Check if there are pending triggers
	 */
	static bool hasPendingTriggers()
	{
		return head != null;
	}
	
	/**
	 * Get next trigger's execution time
	 */
	static long nextTriggerTimeUs()
	{
		if (head == null)
			return long.max;
		
		long nextTime = long.max;
		ScheduledTrigger* node = head;
		
		do
		{
			if (node.executeTimeUs < nextTime)
				nextTime = node.executeTimeUs;
			node = node.next;
		} while (node != head);
		
		return nextTime;
	}
	
	/**
	 * Clear all pending triggers
	 */
	static void clear()
	{
		while (head != null)
		{
			ScheduledTrigger* next = head.next;
			removeScheduledTrigger(head);
		}
		head = null;
		current = null;
	}
}
