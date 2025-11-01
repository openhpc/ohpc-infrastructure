/**
 * OpenHPC Test Results Interactive Features
 * Provides filtering, sorting, and enhanced UX for test results
 */

class TestResultsManager {
    constructor() {
        this.originalRows = [];
        this.currentSort = { column: '', direction: 'asc' };
        this.filters = {
            distribution: '',
            provisioner: '',
            rms: '',
            status: '',
            architecture: '',
            network: '',
            compiler: '',
            search: ''
        };

        this.init();
    }

    init() {
        // Wait for DOM to be ready
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => this.setupEventListeners());
        } else {
            this.setupEventListeners();
        }
    }

    setupEventListeners() {
        // Store original table rows
        this.cacheOriginalRows();
        console.log('Cached rows:', this.originalRows.length);

        // Parse data from existing table rows
        this.parseTestData();
        console.log('Parsed test data:', this.testData.length, 'items');

        // Debug: Show sample parsed data
        if (this.testData.length > 0) {
            console.log('Sample test data:', this.testData[0]);
        }

        // Update summary statistics
        this.updateSummaryStats();

        // Populate filter dropdowns
        this.populateFilters();

        // Setup filter event listeners
        this.setupFilters();

        // Setup table sorting
        this.setupSorting();

        // Setup search
        this.setupSearch();

        console.log('OpenHPC Test Results Dashboard initialized');
    }

    cacheOriginalRows() {
        const tbody = document.querySelector('#results-table tbody');
        if (tbody) {
            this.originalRows = Array.from(tbody.querySelectorAll('tr'));
        }
    }

    parseTestData() {
        this.testData = this.originalRows.map(row => {
            const cells = row.querySelectorAll('td');
            if (cells.length === 0) return null;

            const testName = cells[0]?.textContent?.trim() || '';
            const testLink = cells[0]?.querySelector('a')?.href || '';

            // Parse test configuration from directory name
            const config = this.parseTestConfiguration(testName);

            // Parse status from status icon
            const statusIcon = cells[1]?.querySelector('img');
            let status = 'unknown';
            if (statusIcon) {
                const src = statusIcon.src;
                if (src.includes('test_ok.png')) status = 'pass';
                else if (src.includes('test_error.png')) status = 'fail';
                else if (src.includes('test_warning.png')) status = 'warning';
            }

            // Extract individual test case counts from table cells
            const passedCount = parseInt(cells[3]?.getAttribute('data-passed') || cells[3]?.textContent || '0', 10);
            const failedCount = parseInt(cells[4]?.getAttribute('data-failed') || cells[4]?.textContent || '0', 10);

            return {
                element: row,
                testName,
                testLink,
                status,
                config,
                timestamp: this.extractTimestamp(testName),
                passedCount,
                failedCount
            };
        }).filter(item => item !== null);
    }

    parseTestConfiguration(testName) {
        // Parse test configuration names like: "3.4-almalinux9-confluent-ethernet-gpu-none-x86_64-slurm"
        // or "3.4-almalinux9-warewulf4-ethernet-INTEL-gpu-none-x86_64-slurm"
        // Note: OHPC- prefix has been removed for cleaner display

        let config = {
            distribution: '',
            provisioner: '',
            network: '',
            compiler: '',
            gpu: '',
            architecture: '',
            rms: ''
        };

        // Split by hyphen and process parts
        const parts = testName.split('-');

        for (let i = 0; i < parts.length; i++) {
            const part = parts[i].toLowerCase();
            const originalPart = parts[i];

            // Distribution detection (contains version numbers or known distros)
            if (originalPart.match(/^(almalinux\d+|rocky\d+|leap\d+\.\d+|openEuler_\d+\.\d+)/)) {
                config.distribution = originalPart;
            }
            // Provisioner detection
            else if (part === 'confluent' || part === 'warewulf' || part === 'warewulf4' || part === 'openchami') {
                config.provisioner = originalPart;
            }
            // Network type
            else if (part === 'ethernet' || part === 'infiniband') {
                config.network = originalPart;
            }
            // Compiler detection
            else if (part === 'intel') {
                config.compiler = 'INTEL';
            }
            else if (part === 'gnu' || part.match(/^gnu\d+$/)) {
                config.compiler = 'GNU';
            }
            // GPU detection - look for "gpu" followed by type
            else if (part === 'gpu' && i + 1 < parts.length) {
                config.gpu = parts[i + 1];
                i++; // Skip the next part as we consumed it
            }
            // Architecture detection
            else if (part === 'x86_64' || part === 'aarch64') {
                config.architecture = originalPart;
            }
            // Resource manager (usually at the end)
            else if (part === 'slurm' || part === 'openpbs') {
                config.rms = originalPart;
            }
        }

        // If no explicit compiler found, check for compiler patterns in the name or default to GNU
        if (!config.compiler) {
            if (testName.includes('INTEL')) {
                config.compiler = 'INTEL';
            } else if (testName.match(/gnu\d+/i)) {
                config.compiler = 'GNU';
            } else {
                // Default to GNU compiler if no explicit compiler is specified
                config.compiler = 'GNU';
            }
        }

        // Network defaults to ethernet if not specified
        if (!config.network) {
            config.network = 'ethernet';
        }

        return config;
    }

    extractTimestamp(testName) {
        // Extract timestamp from names like "2024-01-15-14-30-45-PASS-..."
        const timestampMatch = testName.match(/(\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2})/);
        return timestampMatch ? timestampMatch[1] : '';
    }

    updateSummaryStats() {
        const totalConfigurations = this.testData.length;

        // Calculate test case level statistics (same as shell script)
        const totalPassedCases = this.testData.reduce((sum, test) => sum + test.passedCount, 0);
        const totalFailedCases = this.testData.reduce((sum, test) => sum + test.failedCount, 0);
        const totalTestCases = totalPassedCases + totalFailedCases;

        // Use same pass rate calculation as shell script: (TOTAL_PASSED * 100) / (TOTAL_PASSED + TOTAL_FAILED)
        const passRate = totalTestCases > 0 ? Math.round((totalPassedCases * 100) / totalTestCases) : 0;

        // Only update statistics if they haven't been set by the shell script
        // Check if values are still at their default (0 or initial state)
        const totalTestsElement = document.getElementById('total-tests');
        const totalRuntimeElement = document.getElementById('total-runtime');
        const passRateElement = document.getElementById('pass-rate');
        const latestTestsElement = document.getElementById('latest-tests');

        // Only update if the elements still have default values (0, 0h, 0%, etc.)
        if (totalTestsElement && totalTestsElement.textContent === '0') {
            this.updateElement('total-tests', totalConfigurations);
        }
        if (passRateElement && passRateElement.textContent === '0%') {
            this.updateElement('pass-rate', `${passRate}%`);
        }
        if (latestTestsElement && latestTestsElement.textContent === '0') {
            this.updateElement('latest-tests', this.testData.filter(t => t.testName.includes('LATEST')).length);
        }
        if (totalRuntimeElement && totalRuntimeElement.textContent === '0h') {
            this.updateElement('total-runtime', '0h'); // Keep as placeholder - shell script provides accurate runtime
        }
    }

    updateElement(id, value) {
        const element = document.getElementById(id);
        if (element) {
            element.textContent = value;
        }
    }

    populateFilters() {
        // Extract unique values for each filter
        const distributions = [...new Set(this.testData.map(t => t.config.distribution).filter(Boolean))];
        const provisioners = [...new Set(this.testData.map(t => t.config.provisioner).filter(Boolean))];
        const rms = [...new Set(this.testData.map(t => t.config.rms).filter(Boolean))];
        const architectures = [...new Set(this.testData.map(t => t.config.architecture).filter(Boolean))];
        const networks = [...new Set(this.testData.map(t => t.config.network).filter(Boolean))];
        const compilers = [...new Set(this.testData.map(t => t.config.compiler).filter(Boolean))];

        // Debug logging
        console.log('Filter values:');
        console.log('- Distributions:', distributions);
        console.log('- Provisioners:', provisioners);
        console.log('- Resource Managers:', rms);
        console.log('- Architectures:', architectures);
        console.log('- Networks:', networks);
        console.log('- Compilers:', compilers);

        this.populateSelect('filter-distribution', distributions);
        this.populateSelect('filter-provisioner', provisioners);
        this.populateSelect('filter-rms', rms);
        this.populateSelect('filter-architecture', architectures);
        this.populateSelect('filter-network', networks);
        this.populateSelect('filter-compiler', compilers);
    }

    populateSelect(id, options) {
        const select = document.getElementById(id);
        if (!select) return;

        options.sort().forEach(option => {
            const optionElement = document.createElement('option');
            optionElement.value = option;
            optionElement.textContent = option;
            select.appendChild(optionElement);
        });
    }

    setupFilters() {
        // Add event listeners to all filter controls
        Object.keys(this.filters).forEach(filterKey => {
            const element = document.getElementById(`filter-${filterKey}`);
            if (element) {
                element.addEventListener('change', () => {
                    this.filters[filterKey] = element.value;
                    this.applyFilters();
                });
            }
        });
    }

    setupSearch() {
        const searchInput = document.getElementById('search-test');
        if (searchInput) {
            let searchTimeout;
            searchInput.addEventListener('input', () => {
                clearTimeout(searchTimeout);
                searchTimeout = setTimeout(() => {
                    this.filters.search = searchInput.value.toLowerCase();
                    this.applyFilters();
                }, 300); // Debounce search
            });
        }
    }

    setupSorting() {
        const headers = document.querySelectorAll('#results-table th.sortable');
        headers.forEach(header => {
            header.addEventListener('click', () => {
                const sortColumn = header.dataset.sort;
                this.handleSort(sortColumn);
            });
        });
    }

    handleSort(column) {
        // Update sort direction
        if (this.currentSort.column === column) {
            this.currentSort.direction = this.currentSort.direction === 'asc' ? 'desc' : 'asc';
        } else {
            this.currentSort.column = column;
            this.currentSort.direction = 'asc';
        }

        // Update header classes
        this.updateSortHeaders();

        // Apply sort and filters
        this.applyFilters();
    }

    updateSortHeaders() {
        const headers = document.querySelectorAll('#results-table th.sortable');
        headers.forEach(header => {
            header.classList.remove('sort-asc', 'sort-desc');
            if (header.dataset.sort === this.currentSort.column) {
                header.classList.add(`sort-${this.currentSort.direction}`);
            }
        });
    }

    applyFilters() {
        let filteredData = this.testData.filter(item => {
            // Apply all filters
            if (this.filters.distribution && !item.config.distribution.includes(this.filters.distribution)) return false;
            if (this.filters.provisioner && !item.config.provisioner.includes(this.filters.provisioner)) return false;
            if (this.filters.rms && !item.config.rms.includes(this.filters.rms)) return false;
            if (this.filters.architecture && !item.config.architecture.includes(this.filters.architecture)) return false;
            if (this.filters.network && !item.config.network.includes(this.filters.network)) return false;
            if (this.filters.compiler && !item.config.compiler.includes(this.filters.compiler)) return false;
            if (this.filters.status && item.status !== this.filters.status) return false;
            if (this.filters.search && !item.testName.toLowerCase().includes(this.filters.search)) return false;

            return true;
        });

        // Apply sorting
        if (this.currentSort.column) {
            filteredData.sort((a, b) => {
                let aVal, bVal;

                switch (this.currentSort.column) {
                    case 'test':
                        aVal = a.testName;
                        bVal = b.testName;
                        break;
                    case 'status':
                        aVal = a.status;
                        bVal = b.status;
                        break;
                    case 'date':
                        aVal = a.timestamp;
                        bVal = b.timestamp;
                        break;
                    default:
                        aVal = a.testName;
                        bVal = b.testName;
                }

                if (aVal < bVal) return this.currentSort.direction === 'asc' ? -1 : 1;
                if (aVal > bVal) return this.currentSort.direction === 'asc' ? 1 : -1;
                return 0;
            });
        }

        // Update table display
        this.updateTableDisplay(filteredData);

        // Update summary for filtered results
        this.updateFilteredSummary(filteredData);
    }

    updateTableDisplay(filteredData) {
        const tbody = document.querySelector('#results-table tbody');
        if (!tbody) return;

        // Hide all rows first
        this.originalRows.forEach(row => {
            row.style.display = 'none';
        });

        // Show filtered rows in order
        filteredData.forEach((item, index) => {
            item.element.style.display = '';

            // Update row classes for styling
            item.element.classList.remove('odd', 'even');
            item.element.classList.add(index % 2 === 0 ? 'even' : 'odd');

            // Append in correct order
            tbody.appendChild(item.element);
        });

        // Show "no results" message if needed
        if (filteredData.length === 0) {
            this.showNoResultsMessage();
        } else {
            this.hideNoResultsMessage();
        }
    }

    updateFilteredSummary(filteredData) {
        // Calculate test case level statistics for filtered data (same methodology as shell script)
        const totalPassedCases = filteredData.reduce((sum, test) => sum + test.passedCount, 0);
        const totalFailedCases = filteredData.reduce((sum, test) => sum + test.failedCount, 0);
        const totalTestCases = totalPassedCases + totalFailedCases;

        // Use same pass rate calculation as shell script: (TOTAL_PASSED * 100) / (TOTAL_PASSED + TOTAL_FAILED)
        const passRate = totalTestCases > 0 ? Math.round((totalPassedCases * 100) / totalTestCases) : 0;

        // Update pass rate for filtered results
        this.updateElement('pass-rate', `${passRate}%`);
    }

    showNoResultsMessage() {
        const tbody = document.querySelector('#results-table tbody');
        if (!tbody) return;

        let noResultsRow = tbody.querySelector('.no-results-row');
        if (!noResultsRow) {
            noResultsRow = document.createElement('tr');
            noResultsRow.className = 'no-results-row';
            noResultsRow.innerHTML = '<td colspan="6" style="text-align: center; padding: 40px; color: #7f8c8d;">&#128269; No test results match the current filters.</td>';
            tbody.appendChild(noResultsRow);
        }
        noResultsRow.style.display = '';
    }

    hideNoResultsMessage() {
        const noResultsRow = document.querySelector('.no-results-row');
        if (noResultsRow) {
            noResultsRow.style.display = 'none';
        }
    }
}

// Initialize the test results manager
new TestResultsManager();