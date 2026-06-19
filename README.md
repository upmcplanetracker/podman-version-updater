<h1 align="center">Podman Version Updater (Source Build)</h1>
<p align="center"><strong>Build &amp; install any Podman release from GitHub without touching your apt‑managed binary</strong></p>
<hr>

<h2>⚠️ <span style="color:red;">IMPORTANT WARNINGS. READ THIS FIRST</span> ⚠️</h2>

<h3>🛑 <span style="color:darkorange;">This process replaces a system‑level binary</span></h3>
<p>Replacing a core container runtime by compiling from source is a <strong>high‑risk operation</strong>. It worked flawlessly on the author’s machine, but that does <strong>not</strong> guarantee it will work on yours. The script installs a self‑compiled Podman into <code>/usr/local</code>, which <strong>overrides the system package</strong>. This is <strong>not a standard `apt` upgrade</strong> and carries potential for breakage, data loss, or unexpected system behavior.</p>

<h3>📦 <span style="color:darkorange;">Complete backup is mandatory</span></h3>
<p>Before running this script, you <strong>must</strong> back up:</p>
<ul>
  <li>All container data, volumes, and images</li>
  <li>Your entire home directory (or at least <code>~/.local/share/containers</code>)</li>
  <li>Any custom Quadlet unit files</li>
  <li>Full system snapshots (e.g., using Timeshift or LVM) if possible</li>
</ul>
<p>The author takes <strong>zero responsibility</strong> for data loss, broken containers, or unbootable systems. You assume <strong>all risk</strong>.</p>

<h3>🧪 <span style="color:darkorange;">Only tested on Ubuntu 26.04 / Podman 5.7.0 → 5.8.3</span></h3>
<p>This script was written and validated <strong>exclusively</strong> on:</p>
<ul>
  <li><strong>Ubuntu 26.04</strong></li>
  <li><strong>Podman 5.7.0</strong> (apt‑managed package installed with 26.04) upgrading to <strong>v5.8.3</strong></li>
</ul>
<p><strong>If you are using a different OS, a different Podman base version, or a different target version, you must verify that ALL build dependencies are new enough.</strong> Failing to do so will likely cause a build failure and could leave your system in an inconsistent state.</p>

<h3>🧩 <span style="color:darkorange;">Dependency version check is YOUR job</span></h3>
<p>The script installs build dependencies using the current <code>apt</code> packages available on your system. It does <strong>not</strong> check whether those libraries meet the minimum version required by the Podman version you want to build. Before proceeding:</p>
<ul>
  <li>Read the <a href="https://github.com/containers/podman/blob/main/install.md" target="_blank">official Podman build instructions</a> for the tag you are targeting.</li>
  <li>Check the required versions of <code>go</code>, <code>gpgme</code>, <code>systemd</code>, <code>conmon</code>, etc.</li>
  <li>If the required versions are newer than what your distribution ships, you must upgrade those manually – the script will not do it for you.</li>
</ul>

<hr>

<h2>📋 How It Works</h2>
<ol>
  <li>You give the script a GitHub release‑tag URL and a mode: normal update, fresh install, or rollback.</li>
  <li>For upgrades it verifies the target version is <strong>newer</strong> than your current one, backs up your running containers and Podman‑related services.</li>
  <li>It installs all required build dependencies via <code>apt</code>.</li>
  <li>It clones the repository, checks out the tag, and compiles Podman.</li>
  <li>It <strong>safely</strong> stops only <code>podman.service</code> and <code>podman.socket</code> (never your login session).</li>
  <li>It installs the new binary into <code>/usr/local</code> (the original <code>/usr/bin/podman</code> remains untouched).</li>
  <li>It runs <code>podman system migrate</code> (upgrades only) and verifies the new version.</li>
  <li>It restarts your saved Podman services.</li>
  <li><strong>If anything fails during build, install, or verification, the script automatically cleans up any partially installed files, leaving your original Podman fully working.</strong></li>
</ol>

<hr>

<h2>🚀 Usage</h2>

<h3>1. Clone this repository to your machine</h3>
<pre><code>git clone https://github.com/upmcplanetracker/podman-version-updater.git
cd podman-version-updater</code></pre>

<h3>2. Make the script executable</h3>
<pre><code>chmod +x podman-version-updater.sh</code></pre>

<h3>3. Normal update (upgrade an existing Podman)</h3>
<pre><code>./podman-version-updater.sh https://github.com/containers/podman/releases/tag/v5.8.3</code></pre>

<p>For a future release, just change the URL:</p>
<pre><code>./podman-version-updater.sh https://github.com/containers/podman/releases/tag/v5.9.0</code></pre>

<p><strong>Important:</strong> The URL <strong>must</strong> point to a GitHub release tag, not a branch or the main repository page.</p>

<h3>4. Fresh install (no Podman installed yet)</h3>
<pre><code>./podman-version-updater.sh --fresh-install https://github.com/containers/podman/releases/tag/v5.8.3</code></pre>
<p>This will install all necessary runtime dependencies, then build and install Podman from source. No existing Podman is required.</p>

<h3>5. Rollback to the original apt‑managed Podman</h3>
<pre><code>./podman-version-updater.sh --rollback</code></pre>
<p>Stops any Podman services, removes the compiled files from <code>/usr/local</code>, and restores the system binary. It is safe to run even if no locally built version is present.</p>

<h3>6. After a successful update or fresh install – clear your shell’s command hash</h3>
<p><strong>Your terminal may still show the old version number.</strong> This is because your shell cached the old binary’s location. Run one of these:</p>
<pre><code>hash -r          # in the same terminal
# or simply open a new terminal window</code></pre>

<hr>

<h2>🔄 Managing Installed Podman Versions</h2>

<p>After running the updater, your system may have <strong>two</strong> Podman versions:
  <br>• <strong>Source‑built</strong> (e.g., 5.8.3) at <code>/usr/local/bin/podman</code>
  <br>• <strong>APT‑managed</strong> (e.g., 5.7.0) at <code>/usr/bin/podman</code>
</p>

<p>The new version is used automatically because <code>/usr/local/bin</code> comes first in your <code>$PATH</code>.
You can safely keep both – the original binary is untouched and ready as a fallback.</p>

<h3>✅ Option 1 – Keep both (recommended)</h3>
<p>Do nothing extra. This gives you:</p>
<ul>
  <li>The latest features from your compiled version.</li>
  <li>Instant rollback to the APT version with <code>./podman-version-updater.sh --rollback</code>.</li>
  <li>Zero risk of accidentally removing critical runtime dependencies.</li>
</ul>

<h3>🗑️ Option 2 – Use only the source‑built version (remove the APT package)</h3>
<p><strong>Warning:</strong> After doing this, <code>--rollback</code> will <strong>not</strong> work – there will be no fallback binary.</p>

<ol>
  <li>Ensure the source‑built version is working correctly.</li>
  <li><strong>Mark the runtime dependencies as manually installed</strong> so APT won’t auto‑remove them:
    <pre><code>sudo apt-mark manual conmon crun netavark uidmap catatonit</code></pre>
  </li>
  <li>Remove the APT package:
    <pre><code>sudo apt purge podman</code></pre>
  </li>
</ol>

<p>After this, only <code>/usr/local/bin/podman</code> remains. Your containers and images are not affected.</p>

<h3>🔙 Option 3 – Revert completely to the APT version</h3>
<pre><code>./podman-version-updater.sh --rollback</code></pre>
<p>Stops services, removes compiled files, and restores the original system services. No further cleanup is needed.</p>

<h3>⚠️ What happens if you purge the APT version and then try to roll back?</h3>
<p><strong>The rollback will fail.</strong> The script will remove the only remaining Podman binary, and then attempt to verify the restored version – but no binary exists. You would need to reinstall the APT package (<code>sudo apt install podman</code>) to recover.</p>

<hr>

<h2>🧹 Cleanup</h2>
<p>The script creates two backup files in your home directory (during an upgrade, not fresh install):</p>
<ul>
  <li><code>~/podman-state-backup.txt</code> – list of running containers before the upgrade.</li>
  <li><code>~/podman-services-backup.txt</code> – Podman/Quadlet service units that were active.</li>
</ul>
<p>You can delete them after a successful update, or keep them for reference.</p>

<hr>

<p align="center"><strong>Remember: you are modifying system binaries. Proceed with caution, full backups, and a thorough understanding of your own environment.</strong></p>
