import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 20 }, // Ramp up to 20 users in 1m
    { duration: '3m', target: 20 }, // Stay at 20 users for 3m
    { duration: '1m', target: 0 },  // Ramp down to 0
  ],
};

export default function () {
  http.get('http://localhost:9898');
  sleep(1);
}
