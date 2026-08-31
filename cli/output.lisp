(in-package #:ud18.cli)

;;; The three renderings of a reading -- aligned text, JSONL, CSV -- kept in
;;; one file so a field added to the decoder is added to all of them at once.
;;;
;;; Every encoder emits the fields the protocol notes call confirmed, plus
;;; the provisional ones under names that say what they are. The raw frame
;;; rides along in the JSONL so a capture stays re-decodable if a field is
;;; later relabelled: nothing here is lossy.
;;;
;;; A reading with no time on it is a reading you cannot correlate with
;;; anything else, so every format carries one -- hex included, behind the
;;; same '#' comment `decode' already skips, which is also where `decode'
;;; reads it back from. TIMESTAMP is the moment the frame arrived and is
;;; passed in by the caller; when it is genuinely unknown -- decoding a file
;;; that never recorded one -- the field is empty rather than filled with
;;; the current time, which would be a measurement time that is off by
;;; however long the capture sat on disk.

(defun reading-text (r &key timestamp)
  "One aligned line per reading, for a terminal.

The trailing @28 field is the part of the frame nothing is known to read --
bytes 28 to 34. Shown on every line rather than tucked behind a flag: the
manufacturer's own app references those bytes zero times and they are zero
in every frame captured here, so the moment they are not, that is a
discovery, and it should not need anyone to go looking for it."
  (format nil "~@[~A  ~]~6,2F V ~8,2F A ~9,2F W ~10,3F Ah ~10,2F Wh  D-~,2F D+~,2F  ~2DC  ~A  bl ~A  @~D ~A"
          timestamp
          (ud18:reading-volts r)
          (ud18:reading-amps r)
          (ud18:reading-watts r)
          (ud18:reading-capacity-ah r)
          (ud18:reading-energy-wh r)
          (ud18:reading-d-minus-volts r)
          (ud18:reading-d-plus-volts r)
          (ud18:reading-temperature-c r)
          (ud18:format-run-time r)
          (ud18:backlight-description r)
          (ud18:reading-undecoded-offset r)
          (hex-string (ud18:reading-undecoded r))))

(defun json-float (x)
  "A JSON number for X with no reader-dependent exponent markers."
  (format nil "~,4F" x))

(defun reading-jsonl (r &key timestamp mac)
  "One JSON object per reading, newline-terminated by the caller.

Hand-rolled rather than pulled from a JSON library: the schema is fixed and
flat, and the binary should not grow a dependency for eight numbers."
  (format nil "{\"ts\":~A~@[,\"mac\":\"~A\"~],\"volts\":~A,\"amps\":~A,\"watts\":~A,~
\"capacity_mah\":~D,\"energy_wh\":~A,\"d_minus_volts\":~A,\"d_plus_volts\":~A,~
\"temperature_c\":~D,\"run_seconds\":~D,\"run_time\":\"~A\",\"backlight_seconds\":~D,~
\"undecoded\":\"~A\",\"raw\":\"~A\"}"
          (if timestamp (format nil "\"~A\"" timestamp) "null") mac
          (json-float (ud18:reading-volts r))
          (json-float (ud18:reading-amps r))
          (json-float (ud18:reading-watts r))
          (ud18:reading-capacity-mah r)
          (json-float (ud18:reading-energy-wh r))
          (json-float (ud18:reading-d-minus-volts r))
          (json-float (ud18:reading-d-plus-volts r))
          (ud18:reading-temperature-c r)
          (ud18:reading-run-time-seconds r)
          (ud18:format-run-time r)
          (ud18:reading-backlight-seconds r)
          (hex-string (ud18:reading-undecoded r))
          (hex-string (ud18:reading-raw r))))

(defun csv-header (&key mac)
  (format nil "ts~@[,mac~*~],volts,amps,watts,capacity_mah,energy_wh,~
d_minus_volts,d_plus_volts,temperature_c,run_seconds,backlight_seconds,undecoded,raw"
          mac))

(defun reading-csv (r &key timestamp mac)
  (format nil "~A~@[,~A~],~A,~A,~A,~D,~A,~A,~A,~D,~D,~D,~A,~A"
          (or timestamp "") mac
          (json-float (ud18:reading-volts r))
          (json-float (ud18:reading-amps r))
          (json-float (ud18:reading-watts r))
          (ud18:reading-capacity-mah r)
          (json-float (ud18:reading-energy-wh r))
          (json-float (ud18:reading-d-minus-volts r))
          (json-float (ud18:reading-d-plus-volts r))
          (ud18:reading-temperature-c r)
          (ud18:reading-run-time-seconds r)
          (ud18:reading-backlight-seconds r)
          (hex-string (ud18:reading-undecoded r))
          (hex-string (ud18:reading-raw r))))

(defun reading-hex (r &key timestamp)
  "The raw frame as spaced hex, with the arrival time behind a '#'.

The comment is how a hex capture gets a clock without ceasing to be a hex
capture: `decode' already drops everything after the '#', so a file
written this way still reads back byte-for-byte in anything that skips
comments, and READ-TIMESTAMP-COMMENT hands the time back to the decoder
rather than letting it invent one."
  (format nil "~A~@[  # ~A~]"
          (hex-string (ud18:reading-raw r) :separator " ") timestamp))

(defun emit-reading (stream r format &key timestamp mac)
  "Write one reading to STREAM in FORMAT (\"text\", \"jsonl\", \"csv\", \"hex\")."
  (write-string (cond ((string= format "jsonl") (reading-jsonl r :timestamp timestamp :mac mac))
                      ((string= format "csv")   (reading-csv   r :timestamp timestamp :mac mac))
                      ((string= format "hex")   (reading-hex   r :timestamp timestamp))
                      (t                        (reading-text  r :timestamp timestamp)))
                stream)
  (terpri stream))
