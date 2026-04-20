import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 20 }, // Monte à 20 utilisateurs en 1m
    { duration: '3m', target: 20 }, // Reste à 20 utilisateurs pendant 3m
    { duration: '1m', target: 0 },  // Redescend à 0
  ],
};

export default function () {
  http.get('http://localhost:9898');
  sleep(1);
}
