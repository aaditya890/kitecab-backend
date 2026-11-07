# KiteCab WhatsApp templates v2 (MSG91)

Create each one in MSG91 → WhatsApp → Templates → Create New Template, on number 919009611602.
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
New booking #{{1}}

Customer: {{2}}, {{3}}
Trip: {{4}}, {{5}}
Route: {{6}}
Pickup address: {{7}}
Date and time: {{8}}
Passengers: {{9}}
Fare: ₹{{10}} (advance ₹{{11}})

Please assign a driver in the admin panel.
```
Example: `999971`, `Rohit Sharma`, `9876543210`, `One way`, `Sedan`, `Raipur to Bilaspur`, `Telibandha, Raipur`, `25 Oct 2026, 6:30 PM`, `2`, `2200`, `440`

---

## 3. `kc_booking_customer` — to the customer, after booking (one way, round trip and rental)

**Body**
```
Hello {{1}}, your KiteCab booking request is received.

Booking ID: #{{2}}
Trip: {{3}}, {{4}}
Route: {{5}}
Pickup: {{6}}
Date and time: {{7}}
Fare: ₹{{8}}

Pay the advance of ₹{{9}} to confirm your cab. The rest is paid to the driver after the trip.
```
**Footer:** `KiteCab · Taxi service in Chhattisgarh`

**Buttons**
- URL button, dynamic: text `Pay advance`, URL `https://rzp.io/{{1}}` (example `https://rzp.io/rzp/AbC123`)
- Phone button: text `Call KiteCab`, number `+919009611602`

Example: `Rohit`, `999971`, `One way`, `Sedan`, `Raipur to Bilaspur`, `Telibandha, Raipur`, `25 Oct, 6:30 PM`, `2200`, `440`

(Replaces both old customer templates: for a rental, "Route" carries the package, e.g. `Raipur · 8 hours 80 km`.)

---

## 4. `kc_payment_customer` — to the customer, when the advance is paid

**Body**
```
Hello {{1}}, we have received your advance of ₹{{2}}.

Your booking #{{3}} is confirmed. Driver and car details will be sent before pickup.
```
**Footer:** `KiteCab · Taxi service in Chhattisgarh`
**Button:** Phone `Call KiteCab` → `+919009611602`

---

## 5. `kc_payment_admin` — to admin numbers, when the advance is paid

**Body**
```
Advance received for booking #{{1}}

Customer: {{2}}, {{3}}
Amount: ₹{{4}}
Payment ID: {{5}}

The booking is now confirmed.
```

---

## 6. `kc_driver_assigned` — NEW, to the customer, when admin assigns a driver

**Body**
```
Hello {{1}}, your driver for booking #{{2}} is assigned.

Driver: {{3}}
Driver mobile: {{4}}
Car: {{5}}, {{6}}
Pickup: {{7}}

Have a safe trip with KiteCab.
```
Example: `Rohit`, `999971`, `Ramesh Sahu`, `9827012345`, `Swift Dzire`, `CG 04 AB 1234`, `25 Oct, 6:30 PM`

---

## After approval

Send me a screenshot of the approved list. The code then switches to these names in one file
(`lib/whatsapp.ts`); admin numbers stay in Admin → Settings, so each number can be added or removed there.
