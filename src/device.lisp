(in-package #:ud18)

;;; Talking to a UD18: connect, subscribe, stream readings, send commands.
;;;
;;; This is the whole of ud18/ble now. Everything underneath -- HCI sockets,
;;; adapter enumeration, LE scanning, the ATT/GATT client, and both LE
;;; transports -- is the shared `ble' system. This file used to sit on top of
;;; a private copy of all of that, about 1200 lines of it, which had drifted
;;; into being a slightly better implementation of the same thing. The
;;; improvements were moved into `ble'; the copy is gone.
;;;
;;; What is left here is genuinely UD18-specific: which characteristic carries
;;; the data, what counts as a UD18 during a scan, and the fact that the meter
;;; talks the moment you subscribe and never stops.

(defparameter *att-mtu* 247
  "The ATT MTU to request when connecting.

Not the library default, which is 23, and the difference is not cosmetic. A
23-byte MTU leaves 20 bytes of notification payload, so the meter's 36-byte
report arrives split across two notifications and every frame fails to decode
on a length check. `ble' defaults low on purpose -- it keeps each PDU inside
one HCI ACL packet for the short NUS commands it was written for -- but this
device streams fixed 36-byte frames and wants them whole.")

(defparameter +ud18-service-uuid+ (uuid16 #xFFE0)
  "The serial-bridge service. Advertised, which is what UD18-LIKE-P uses to
recognise a meter whose name did not make it into the scan window.")

(defparameter +ud18-char-uuid+ (uuid16 #xFFE1)
  "The one characteristic that matters: notify for the measurement stream,
write for commands.")

;;; --- finding one -------------------------------------------------------

(defun ud18-like-p (d)
  "True when a discovered device looks like a UD18: an ATORCH-style name, or
the 0xFFE0 serial-bridge service it carries its measurements on."
  (or (and (discovered-name d)
           (let ((n (string-upcase (discovered-name d))))
             (or (search "UD18" n) (search "ATORCH" n))))
      (member #xFFE0 (discovered-service-uuids d))))

(defun find-meters (&key (dev 0) (seconds 8) all)
  "Scan for SECONDS and return the UD18-like devices found, strongest first.
ALL returns every advertiser instead.

Legacy scanning, not extended: the UD18 is an ordinary 1M-PHY advertiser, and
the legacy commands work on controllers that never implemented the extended
ones."
  (discover :dev dev :seconds seconds :extended nil
            :filter (unless all #'ud18-like-p)))

;;; --- the connection ----------------------------------------------------

(defstruct (connection (:constructor %make-connection))
  "An open connection to a UD18.

CHAN is an ATT channel in the `ble' sense: an integer fd for a kernel L2CAP
socket, or an HCI-CONN when we have taken the adapter over. Nothing here needs
to care which -- the ATT layer dispatches on it."
  chan transport mtu address addr-type value-handle cccd-handle
  (frames 0) (bad-frames 0))

(defun %open-att-channel (addr transport addr-type timeout dev retries)
  (ecase transport
    (:hci-user (hci-user-att-connect addr :addr-type addr-type :dev dev
                                          :timeout timeout :retries retries
                                          ;; The meter is a legacy 1M-PHY
                                          ;; advertiser, and the Pi's built-in
                                          ;; radio -- the only one that hears
                                          ;; it here -- may not implement LE
                                          ;; Extended Create Connection.
                                          :command :legacy))
    (:l2cap    (l2cap-att-connect addr :addr-type addr-type :timeout timeout :dev dev))))

(defun connect (mac &key (addr-type :public) (transport :hci-user)
                         (timeout 15) (dev 0) (retries 1))
  "Connect to the UD18 at MAC, discover characteristic 0xFFE1, and subscribe.
MAC is a display-order string (\"CB:3B:7F:8E:75:A3\") or 6 octets already in
on-air order.

ADDR-TYPE is :public or :random. The unit tested here advertises a public
address despite its locally-administered-looking OUI, so :public is the
default; `ud18 scan' prints what any given meter actually uses.

TRANSPORT selects how the LE link is made:

  :hci-user  take hci<DEV> away from the kernel and drive HCI ourselves. The
             default, because it has never failed on the Pi this was built
             against -- including from a state that defeated the kernel path
             entirely. Disturbs anything else using that adapter, and needs
             CAP_NET_ADMIN as well as CAP_NET_RAW.
  :l2cap     ask the kernel to connect and speak ATT over an L2CAP socket.
             Leaves the adapter with the kernel and needs no CAP_NET_ADMIN,
             so it is the better neighbour -- but it has been observed to
             hang indefinitely on a wedged controller.

Returns a CONNECTION. The meter starts streaming immediately, about one frame
a second, so call NEXT-READING promptly rather than connecting and wandering
off, or you will be reading measurements from a minute ago."
  (let* ((addr (if (stringp mac) (parse-mac mac) (coerce-octets mac)))
         (chan (%open-att-channel addr transport addr-type timeout dev retries))
         (conn (%make-connection :chan chan :transport transport :mtu 23
                                 :address addr :addr-type addr-type)))
    (handler-case
        (progn
          (setf (connection-mtu conn) (att-exchange-mtu chan *att-mtu*))
          (let* ((chars (att-discover-characteristics chan))
                 (ch (find-char-by-uuid chars +ud18-char-uuid+)))
            (unless ch
              (error 'characteristic-not-found
                     :address (format-mac addr)
                     :found (mapcar #'gatt-char-uuid-string chars)))
            (setf (connection-value-handle conn) (gatt-char-handle ch)
                  ;; Fall back to handle+1: the CCCD conventionally sits
                  ;; directly after the value, and HM-10 clones have been
                  ;; known to answer Find-Information with an error rather
                  ;; than a descriptor list.
                  (connection-cccd-handle conn)
                  (or (att-find-cccd chan (gatt-char-handle ch))
                      (1+ (gatt-char-handle ch))))
            (att-subscribe chan (connection-cccd-handle conn)))
          conn)
      (error (c) (att-channel-close chan) (error c)))))

(defun disconnect (conn)
  "Close the connection, handing the adapter back to the kernel if we took it.
Idempotent.

The channel deregisters itself from BLE:*OPEN-ATT-CHANNELS* on the way out,
so an interrupted process still releases the adapter -- see
BLE:INSTALL-ADAPTER-TEARDOWN, which cli/main.lisp calls."
  (when (connection-chan conn)
    (att-channel-close (connection-chan conn))
    (setf (connection-chan conn) nil))
  conn)

(defmacro with-connection ((var mac &rest args) &body body)
  "Bind VAR to a CONNECTION to MAC for BODY, closing it however BODY leaves."
  `(let ((,var (connect ,mac ,@args)))
     (unwind-protect (progn ,@body)
       (disconnect ,var))))

;;; --- reading -----------------------------------------------------------

(defun next-frame (conn &key (timeout-ms 5000))
  "The next raw octets from the meter, or NIL on timeout."
  (let ((pdu (att-next-notification (connection-chan conn)
                                    (connection-value-handle conn) timeout-ms)))
    (when (vectorp pdu) pdu)))

(defun next-reading (conn &key (timeout-ms 5000) (verify-checksum t))
  "The next decoded READING, or NIL on timeout.

Returns (VALUES READING RAW-FRAME CONDITION). A frame that fails to decode is
counted in CONNECTION-BAD-FRAMES and returned as (VALUES NIL RAW COND) rather
than signalling -- one corrupt notification is not a reason to tear down a
stream that will produce another a second later."
  (let ((frame (next-frame conn :timeout-ms timeout-ms)))
    (when frame
      (incf (connection-frames conn))
      (multiple-value-bind (reading condition)
          (decode-frame-or-nil frame :verify-checksum verify-checksum)
        (unless reading (incf (connection-bad-frames conn)))
        (values reading frame condition)))))

(defun stream-readings (conn callback &key seconds max-frames (timeout-ms 5000)
                                           (verify-checksum t) on-error)
  "Call CALLBACK with each READING as it arrives.

Stops after SECONDS or MAX-FRAMES, whichever comes first; with neither, runs
until CALLBACK performs a non-local exit or the meter goes away. Frames that
fail to decode go to ON-ERROR (called with the condition and the raw frame)
when supplied. Returns the number of readings delivered."
  (let ((deadline (when seconds
                    (+ (get-internal-real-time)
                       (round (* seconds internal-time-units-per-second)))))
        (delivered 0)
        (idle 0))
    (loop
      (when (and deadline (>= (get-internal-real-time) deadline)) (return))
      (when (and max-frames (>= delivered max-frames)) (return))
      (multiple-value-bind (reading raw condition)
          (next-reading conn :timeout-ms (min timeout-ms 500)
                             :verify-checksum verify-checksum)
        (cond (reading (setf idle 0)
                       (incf delivered)
                       (funcall callback reading))
              (condition (setf idle 0)
                         (when on-error (funcall on-error condition raw)))
              (t
               ;; Nothing in that poll slice. The meter emits about one frame
               ;; a second, so a long run of empty slices means the link is
               ;; gone rather than that we were early.
               (incf idle 500)
               (when (>= idle timeout-ms) (return))))))
    delivered))

;;; --- commands ----------------------------------------------------------

(defun find-reply (buffer)
  "Scan BUFFER for the first well-formed reply frame, or NIL.

Checksum-validating each candidate is what makes this safe: it lets us
resynchronise on a stream that may start mid-frame, or carry stray bytes from
the BLE module's own AT interpreter -- which really does interleave text into
this channel -- without mistaking any of it for a reply."
  (when (>= (length buffer) +reply-frame-length+)
    (loop for i from 0 to (- (length buffer) +reply-frame-length+)
          for candidate = (subseq buffer i (+ i +reply-frame-length+))
          when (reply-frame-p candidate) return candidate)))

(defun drain (conn &key (timeout-ms 12000))
  "Consume queued notifications until the meter goes quiet or a live report
arrives. Returns T if a report was seen.

The timeout is long because it is only ever paid when something is wrong.
Reports arrive about once a second, so a healthy link returns here almost
immediately; the full window is spent only when the notification path is down,
and that state has been observed clearing by itself within seconds. Waiting it
out turns a transient outage into a normal command rather than a failure the
caller has to interpret.

Two jobs, both about making the next command interpretable. It empties frames
that were already in flight, so they cannot eat the reply deadline or land in
the scan buffer; and seeing a report proves notifications are actually flowing
on this link right now, which a successful CCCD write does not -- subscribing
and writing back-to-back can put a command on the wire before the peer has
begun sending, and the reply is then dropped by the peer rather than by us."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout-ms internal-time-units-per-second) 1000))))
    (loop while (< (get-internal-real-time) deadline)
          for f = (next-frame conn :timeout-ms 400)
          do (when (and f (= (length f) +frame-length+) (frame-magic-p f)
                        (= (frame-class f) +class-report+))
               (return t)))))

(defun send-command (conn command &key (value 0) (device-type +device-usb+)
                                       (timeout-ms 8000) (write-mode :request)
                                       (settle t) (require-notify t))
  "Send COMMAND (a keyword from UD18:+COMMANDS+, or a raw opcode) and wait for
the meter's reply.

Returns (VALUES REPLY FRAME DELIVERY). DELIVERY reports what happened to the
write itself, independently of whether a reply came back:

  :ACKNOWLEDGED    the peer's GATT server accepted the write
  :NOT-SENT        nothing was transmitted: the meter is not notifying, so no
                   reply could have come back. REQUIRE-NOTIFY, on by default.
  :TIMEOUT         no Write Response -- the command did not get there
  :UNACKNOWLEDGED  sent as a Write Command; nothing can be concluded
  an integer       the peer refused the write, with that ATT error code

:NOT-SENT and :TIMEOUT are the two outcomes that are safe to retry, because in
both the command provably never reached the meter.

That distinction is the point. 0xFFE1 carries both the `write' and
`write-without-response' properties, and this used to take the latter: a
fire-and-forget write makes a lost command and an ignored command look
identical, which is what made silence uninterpretable. With WRITE-MODE
:REQUEST -- the default -- silence after an :ACKNOWLEDGED write means the
meter had the command and did not answer, and silence after a :TIMEOUT means
it never arrived. Pass :COMMAND for the old fire-and-forget behaviour.

The fourth value, NOTIFYING, is what SETTLE measured: T if a live measurement
report arrived before the command was sent. It is the difference between the
two ways silence happens. This firmware's notification path can stop entirely
-- no replies AND no measurement reports, while the GATT server keeps
acknowledging writes -- and it stays down until the meter is power cycled.
Observed directly: six acknowledged commands in a row drew no reply, and a
twelve-second monitor over the same link produced 0 readings. NOTIFYING NIL
says the reply could not have arrived whatever the meter did with the command,
so it is a fact about the link, not about the command.

This deliberately does NOT retry -- half the command set is key presses, and
re-sending one that did arrive presses the key twice. A caller that knows its
command is idempotent can retry on DELIVERY :TIMEOUT, where the write provably
did not land."
  ;; Refusing to write into a dead notification path is what makes that case
  ;; safe to retry. The command could not be answered, so sending it would only
  ;; produce an unattributable side effect -- and for the half of the command
  ;; set that is key presses, a retry after that would press the key twice.
  ;; Not sending keeps the retry provably free.
  (let* ((notifying (if settle (drain conn) :unknown))
         (chan (connection-chan conn))
         (handle (connection-value-handle conn))
         (frame (encode-command command :value value :device-type device-type))
         (delivery (cond
                     ((and require-notify (null notifying))
                      (return-from send-command (values nil nil :not-sent nil)))
                     (t (ecase write-mode
                          (:request
                           (let ((r (att-write-value chan handle frame)))
                             (cond ((eq r t) :acknowledged)
                                   ((eq r :timeout) :timeout)
                                   (t r))))
                          (:command
                           (att-write-command chan handle frame)
                           :unacknowledged))))))
    (if (eq delivery :timeout)
        (values nil nil delivery notifying)
        (let ((deadline (+ (get-internal-real-time)
                           (round (* timeout-ms internal-time-units-per-second) 1000)))
              (buffer (make-octets 0)))
          (loop while (< (get-internal-real-time) deadline)
                for f = (next-frame conn :timeout-ms 500)
                do (when (and f (not (and (= (length f) +frame-length+)
                                          (frame-magic-p f)
                                          (= (frame-class f) +class-report+))))
                     (setf buffer (concatenate '(simple-array (unsigned-byte 8) (*))
                                               buffer f))
                     (let ((reply (find-reply buffer)))
                       (when reply
                         (return-from send-command
                           (values (decode-reply reply) reply delivery notifying))))))
          (values nil nil delivery notifying)))))

(defun send-raw-command (conn body &key (class +class-command+) (device-type +device-usb+))
  "Frame BODY as FF 55 CLASS DEVICE-TYPE BODY... CHECKSUM and write it.

The escape hatch, for probing frames SEND-COMMAND cannot express. Note that a
command frame the meter accepts is ten octets -- BODY of five -- and that
anything else is dropped without a reply."
  (att-write-command (connection-chan conn)
                     (connection-value-handle conn)
                     (encode-frame class device-type body)))
