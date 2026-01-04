const http = require('http');
const { spawn, execSync } = require('child_process');
const url = require('url');
const fs = require('fs');
const path = require('path');

const PORT = 8099;
const QUEUE_FILE = '/data/queue.json';
const INVESTIGATED_FILE = '/data/investigated.json';
const WORKER_LOCK = '/data/worker.lock';

// Initialize state files
function initState() {
    if (!fs.existsSync(QUEUE_FILE)) {
        fs.writeFileSync(QUEUE_FILE, '[]');
    }
    if (!fs.existsSync(INVESTIGATED_FILE)) {
        fs.writeFileSync(INVESTIGATED_FILE, '{}');
    }
}

// Read JSON file safely
function readJson(file, defaultValue) {
    try {
        return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
        return defaultValue;
    }
}

// Write JSON file
function writeJson(file, data) {
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

// Check if issue is investigated
function isInvestigated(repo, issue) {
    const investigated = readJson(INVESTIGATED_FILE, {});
    return (investigated[repo] || []).includes(issue);
}

// Check if issue is in queue
function isQueued(repo, issue) {
    const queue = readJson(QUEUE_FILE, []);
    return queue.some(item => item.repo === repo && item.issue === issue);
}

// Add to queue
function addToQueue(repo, issue) {
    if (isInvestigated(repo, issue) || isQueued(repo, issue)) {
        return false;
    }
    const queue = readJson(QUEUE_FILE, []);
    queue.push({
        repo,
        issue,
        added: new Date().toISOString()
    });
    writeJson(QUEUE_FILE, queue);
    return true;
}

// Get open issues from GitHub
function getOpenIssues(repo) {
    try {
        const output = execSync(
            `gh issue list --repo "${repo}" --state open --json number --jq '.[].number'`,
            { encoding: 'utf8', timeout: 30000 }
        );
        return output.trim().split('\n').filter(Boolean).map(Number);
    } catch (e) {
        console.error(`Failed to fetch open issues for ${repo}:`, e.message);
        return [];
    }
}

// Check if worker is running
function isWorkerRunning() {
    if (!fs.existsSync(WORKER_LOCK)) return false;
    try {
        const pid = parseInt(fs.readFileSync(WORKER_LOCK, 'utf8').trim());
        process.kill(pid, 0); // Check if process exists
        return true;
    } catch {
        return false;
    }
}

// Start worker
function startWorker() {
    const logFile = `/data/logs/worker-${new Date().toISOString().replace(/[:.]/g, '-')}.log`;
    const logStream = fs.openSync(logFile, 'a');

    const child = spawn('/worker.sh', [], {
        detached: true,
        stdio: ['ignore', logStream, logStream],
        env: process.env
    });
    child.unref();
    fs.closeSync(logStream);  // Close FD in parent after spawn

    console.log(`Worker started with PID ${child.pid}, logging to ${logFile}`);
    return child.pid;
}

// Handle investigate request
function handleInvestigate(repo, issue, res) {
    initState();

    const added = addToQueue(repo, issue);
    console.log(`Issue ${repo}#${issue}: ${added ? 'added to queue' : 'already queued/investigated'}`);

    // Catchup scan
    console.log(`Scanning for uninvestigated issues in ${repo}...`);
    const openIssues = getOpenIssues(repo);
    let catchupCount = 0;

    for (const issueNum of openIssues) {
        if (addToQueue(repo, issueNum)) {
            console.log(`Catchup: added ${repo}#${issueNum}`);
            catchupCount++;
        }
    }

    const queue = readJson(QUEUE_FILE, []);
    console.log(`Queue length: ${queue.length}, catchup added: ${catchupCount}`);

    // Start worker if needed
    let workerStatus;
    if (isWorkerRunning()) {
        workerStatus = 'already_running';
        console.log('Worker already running');
    } else if (queue.length > 0) {
        startWorker();
        workerStatus = 'started';
    } else {
        workerStatus = 'not_needed';
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
        status: 'queued',
        repo,
        issue,
        queue_length: queue.length,
        catchup_added: catchupCount,
        worker: workerStatus
    }));
}

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);

    if (req.method === 'POST' && parsedUrl.pathname === '/investigate') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const repo = data.repo;
                const issue = parseInt(data.issue);

                // Validate repo format (owner/repo)
                const repoPattern = /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/;
                if (!repo || !repoPattern.test(repo)) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Invalid repo format (expected owner/repo)' }));
                    return;
                }

                if (!issue) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Missing repo or issue' }));
                    return;
                }

                handleInvestigate(repo, issue, res);
            } catch (e) {
                console.error('Error:', e);
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
    } else if (req.method === 'GET' && parsedUrl.pathname === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok' }));
    } else if (req.method === 'GET' && parsedUrl.pathname === '/queue') {
        initState();
        const queue = readJson(QUEUE_FILE, []);
        const investigated = readJson(INVESTIGATED_FILE, {});
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            queue_length: queue.length,
            queue,
            investigated,
            worker_running: isWorkerRunning()
        }));
    } else {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found' }));
    }
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Investigation server listening on port ${PORT}`);
    initState();
});
