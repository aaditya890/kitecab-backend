# KiteCab WhatsApp templates v2 (MSG91)

**Status: all 6 submitted in MSG91 on 7 Nov 2026 (number 919009611602), waiting for Meta approval.**
The texts below are exactly what was submitted (two were lengthened because Meta rejects
templates with too many variables for their length).
Category **Utility**, language **English**. Copy the text exactly; `{{n}}` are variables.
The old templates keep working until the code is switched to these names after approval.

Meta rules that get templates rejected: a variable at the very start or end of the body,
two variables next to each other, promotional words in a Utility template. The texts below avoid all three.

---

## 1. `kc_enquiry_admin` — to admin numbers, on every "Check price"

**Body**
```
New enquiry on kitecab.com

Service: {{1}}
Pickup: {{2}}
Drop / package: {{3}}
Customer mobile: {{4}}
Time: {{5}}

Please call the customer if they have not booked.
```
Example values: `One way`, `Raipur`, `Bilaspur`, `9876543210`, `24 Oct, 4:51 PM`

---

## 2. `kc_booking_admin` — to admin numbers, on every new booking

**Body**
```
KiteCab: a new cab booking has been received on the website.

Booking ID: #{{1}}
Customer name: {{2}}
Customer mobile: {{3}}
Trip type and car: {{4}}
Route: {{5}}
Pickup address: {{6}}
Pickup date and time: {{7}}
Number of passengers: {{8}}
Total fare: ₹{{9}}, advance: ₹{{10}}

Please assign a driver and a car for this booking in the KiteCab admin panel.
```
Example: `999971`, `Rohit Sharma`, `9876543210`, `One way, Sedan`, `Raipur to Bilaspur`, `Telibandha, Raipur`, `25 Oct 2026, 6:30 PM`, `2`, `2200`, `440`

---

## 3. `kc_booking_customer` — to the customer, after booking (one way, round trip and rental)

**Body**
```
Hello {{1}}, your KiteCab booking request has been received.

Booking ID: #{{2}}
Trip type and car: {{3}}
Route: {{4}}
Pickup address: {{5}}
Pickup date and time: {{6}}
Total fare: ₹{{7}}

Please pay the advance of ₹{{8}} using the button below to confirm your cab. The remaining amount is paid to the driver after the trip.
```
**Footer:** `KiteCab - Taxi service in Chhattisgarh`

**Buttons**
- Visit website, dynamic: `Pay advance` → `https://rzp.io/{{1}}` (button_1 = link without `https://rzp.io/`)
- Call phone number: `Call KiteCab` → +91 9009611602

For a rental, "Route" carries the package, e.g. `Raipur · 8 hours 80 km`.

---

## 4. `kc_payment_customer` — to the customer, when the advance is paid

**Body**
```
Hello {{1}}, we have received your advance payment of ₹{{2}} for KiteCab booking #{{3}}.

Your cab booking is now confirmed. The driver name, mobile number and car number will be sent to you on WhatsApp before your pickup time.
```
**Footer:** `KiteCab - Taxi service in Chhattisgarh` · **Button:** Call phone number `Call KiteCab` → +91 9009611602

---

## 5. `kc_payment_admin` — to admin numbers, when the advance is paid

**Body**
```
KiteCab: an advance payment has been received for a cab booking.

Booking ID: #{{1}}
Customer name: {{2}}
Customer mobile: {{3}}
Advance amount: ₹{{4}}
Razorpay payment ID: {{5}}

The booking is now confirmed. Please make sure a driver is assigned before pickup.
```

---

## 6. `kc_driver_assigned` — NEW, to the customer, when admin assigns a driver

**Body**
```
Hello {{1}}, the driver for your KiteCab booking #{{2}} has been assigned.

Driver name: {{3}}
Driver mobile: {{4}}
Car model: {{5}}
Car number: {{6}}
Pickup date and time: {{7}}

Please be ready at the pickup point on time. Have a safe and comfortable trip with KiteCab.
```

---

## After approval

Send me a screenshot of the approved list. The code then switches to these names in one file
(`lib/whatsapp.ts`); admin numbers stay in Admin → Settings, so each number can be added or removed there.
